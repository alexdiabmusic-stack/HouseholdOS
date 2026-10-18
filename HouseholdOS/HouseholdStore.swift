import Foundation
import Observation

@Observable @MainActor final class HouseholdStore {
    let backend: BackendClient
    private(set) var household: SharedHousehold?
    private(set) var households: [SharedHousehold] = []
    private(set) var members: [SharedMember] = []
    private(set) var records: [SharedRecord] = []
    private(set) var activities: [SharedActivity] = []
    private(set) var invites: [SharedInvite] = []
    private(set) var pending: [PendingMutation] = []
    private(set) var conflicts: [RecordConflict] = []
    private(set) var isSyncing = false
    private(set) var lastSynced: Date?
    var error: String?
    private(set) var isLocal = false
    private var sendingID: UUID?
    private var generation = UUID()
    private var cacheUnreadable = false

    init(backend: BackendClient) { self.backend = backend }

    private var localUserID: UUID {
        if let raw = UserDefaults.standard.string(forKey: "hh.localUserID"), let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: "hh.localUserID")
        return id
    }
    var userID: UUID { isLocal ? localUserID : backend.session?.user.id ?? localUserID }
    var myMember: SharedMember? { members.first { $0.userID == userID } }
    var isOwner: Bool { myMember?.role == "owner" }
    var canManageMoney: Bool { myMember?.role != "child" && household != nil }
    var syncLabel: String {
        if isLocal { return "Saved on this device" }
        if isSyncing { return "Syncing…" }
        if !conflicts.isEmpty { return "\(conflicts.count) edit conflict(s) to review" }
        if !pending.isEmpty { return "\(pending.count) change(s) waiting to sync" }
        if let lastSynced { return "Synced \(lastSynced.formatted(.relative(presentation: .named)))" }
        return "Waiting to sync"
    }

    func name(for id: UUID?) -> String {
        guard let id else { return "Unassigned" }
        return members.first { $0.userID == id }?.displayName ?? "Former member"
    }

    func visible(_ kind: RecordKind, parent: UUID? = nil) -> [SharedRecord] {
        records.filter { !$0.deleted && $0.kind == kind && (parent == nil || $0.payload.parentID == parent) }
            .sorted {
                if $0.isFinished != $1.isFinished { return !$0.isFinished }
                if $0.payload.dueAt != $1.payload.dueAt { return ($0.payload.dueAt ?? .distantFuture) < ($1.payload.dueAt ?? .distantFuture) }
                return $0.updatedAt < $1.updatedAt
            }
    }

    func restore() async {
        if backend.session != nil {
            isLocal = false
            loadCachedSelection()
            await loadMemberships()
        } else if UserDefaults.standard.bool(forKey: "hh.localMode") {
            isLocal = true
            loadCachedSelection()
        }
    }

    func createLocal(name: String, displayName: String) throws {
        reset()
        isLocal = true
        let h = SharedHousehold(id: UUID(), name: name, timezone: TimeZone.current.identifier, currency: "CAD")
        household = h
        households = [h]
        members = [SharedMember(householdID: h.id, userID: userID, displayName: displayName, role: "owner")]
        UserDefaults.standard.set(true, forKey: "hh.localMode")
        saveSelection()
        try persist()
    }

    @discardableResult func reopenLocal() -> Bool {
        reset()
        isLocal = true
        loadCachedSelection()
        guard household != nil else { isLocal = false; return false }
        households = household.map { [$0] } ?? []
        UserDefaults.standard.set(true,forKey:"hh.localMode")
        return true
    }

    func loadMemberships() async {
        guard !isLocal, backend.session != nil else { return }
        do {
            let available: [SharedHousehold] = try await backend.get("rest/v1/households?select=*&order=created_at")
            households = available
            if let active = household, !available.contains(where: { $0.id == active.id }) {
                try? FileManager.default.removeItem(at: cacheURL(active.id))
                clearActive()
                error = "You no longer have access to that household."
            }
            if household == nil, let first = available.first { select(first) }
            await sync()
        } catch { self.error = error.localizedDescription }
    }

    func create(name: String, displayName: String) async throws {
        let created: SharedHousehold = try await backend.rpc("create_household", ["p_name":name,"p_display_name":displayName,"p_timezone":TimeZone.current.identifier,"p_currency":"CAD"])
        select(created)
        await loadMemberships()
    }

    func join(token: String, displayName: String) async throws {
        let _: UUID = try await backend.rpc("accept_invite", ["p_token":token.trimmingCharacters(in: .whitespacesAndNewlines),"p_display_name":displayName])
        await loadMemberships()
    }

    func select(_ selected: SharedHousehold) {
        guard selected.id != household?.id else { return }
        clearActive()
        household = selected
        loadCache(selected.id)
        saveSelection()
    }

    func invite(email: String, role: String) async throws -> SharedInvite {
        guard let household, !isLocal else { throw BackendError.configuration }
        struct Body: Encodable { let p_household_id: UUID; let p_email: String; let p_role: String }
        let result: SharedInvite = try await backend.rpc("create_invite", Body(p_household_id: household.id,p_email:email,p_role:role))
        await sync()
        return result
    }

    func revoke(_ invite: SharedInvite) async throws {
        let _: JSONValue = try await backend.rpc("revoke_invite", ["p_invite_id":invite.id])
        await sync()
    }

    func remove(_ member: SharedMember) async throws {
        let _: JSONValue = try await backend.rpc("remove_member", ["p_household_id":member.householdID,"p_user_id":member.userID])
        await loadMemberships()
    }

    func transferOwnership(to member: SharedMember) async throws {
        let _: JSONValue = try await backend.rpc("transfer_ownership", ["p_household_id":member.householdID,"p_user_id":member.userID])
        await sync()
    }

    @discardableResult func add(_ kind: RecordKind, fields: SharedFields) throws -> SharedRecord {
        guard let household else { throw BackendError.server("Create or join a household first.") }
        let record = SharedRecord(id:UUID(),householdID:household.id,kind:kind,payload:fields,version:0,deleted:false,updatedBy:userID,updatedAt:Date())
        try save(record)
        return record
    }

    func save(_ draft: SharedRecord) throws {
        guard draft.householdID == household?.id else { throw BackendError.server("Choose the correct household first.") }
        guard conflicts.allSatisfy({ $0.id != draft.id }) else { throw BackendError.server("Resolve the existing edit conflict first.") }
        let snapshot = records
        let oldQueue = pending
        var edited = draft
        edited.updatedBy = userID
        edited.updatedAt = Date()
        edited.version += 1
        replace(edited)
        if isLocal {
            if draft.kind == .list && draft.deleted {
                for i in records.indices where records[i].payload.parentID == draft.id { records[i].deleted = true }
            }
            createLocalRecurrence(old: snapshot.first { $0.id == draft.id }, new: edited)
        } else {
            pending.append(PendingMutation(record:edited,baseVersion:draft.version))
        }
        do { try persist() }
        catch { records = snapshot; pending = oldQueue; throw error }
        if !isLocal { Task { await sync() } }
    }

    func toggle(_ record: SharedRecord) throws {
        var changed = record
        if record.kind == .bill {
            changed.payload.paid.toggle()
            changed.payload.paidByID = changed.payload.paid ? userID : nil
            changed.payload.paidAt = changed.payload.paid ? Date() : nil
        } else {
            changed.payload.completed.toggle()
            changed.payload.completedAt = changed.payload.completed ? Date() : nil
            if changed.payload.completed { for i in changed.payload.subtasks.indices { changed.payload.subtasks[i].completed = true } }
        }
        try save(changed)
    }

    func delete(_ record: SharedRecord) throws {
        var changed = record
        changed.deleted = true
        try save(changed)
    }

    func duplicate(_ record: SharedRecord) throws {
        var fields = record.payload
        fields.completed = false; fields.completedAt = nil
        fields.paid = false; fields.paidByID = nil; fields.paidAt = nil; fields.previousID = nil
        _ = try add(record.kind, fields:fields)
    }

    func reuseList(_ list:SharedRecord) throws {
        var fields = list.payload
        fields.title += " copy"; fields.shoppingByID = nil
        let copy = try add(.list,fields:fields)
        for item in visible(.item,parent:list.id) {
            var itemFields = item.payload
            itemFields.parentID = copy.id; itemFields.completed = false; itemFields.completedAt = nil
            try add(.item,fields:itemFields)
        }
    }

    func resolve(_ conflict: RecordConflict, keepDraft: Bool) throws {
        // Resolve explicitly against the current server version. Deleted records
        // remain deleted; preserving a draft creates a new record in that case.
        conflicts.removeAll { $0.id == conflict.id }
        if let remote = conflict.remote { replace(remote) }
        else { records.removeAll { $0.id == conflict.id } }
        if keepDraft {
            if conflict.remote?.deleted != false {
                var fields = conflict.draft.payload
                if conflict.draft.kind == .item && !records.contains(where: { $0.id == fields.parentID && !$0.deleted }) {
                    let recovered = try add(.list,fields:SharedFields(title:"Recovered items"))
                    fields.parentID = recovered.id
                }
                _ = try add(conflict.draft.kind, fields:fields)
            } else if let remote = conflict.remote {
                var draft = conflict.draft
                draft.version = remote.version
                try save(draft)
            }
        }
        try persist()
    }

    func sync() async {
        guard !isLocal, !isSyncing, let active = household, backend.session != nil else { return }
        let requestGeneration = generation
        isSyncing = true
        defer { if generation == requestGeneration { isSyncing = false; sendingID = nil } }
        do {
            let roster: [SharedMember] = try await backend.get("rest/v1/household_members?household_id=eq.\(active.id)&select=*")
            guard generation == requestGeneration else { return }
            guard roster.contains(where: { $0.userID == userID }) else {
                try? FileManager.default.removeItem(at: cacheURL(active.id))
                households.removeAll { $0.id == active.id }
                UserDefaults.standard.removeObject(forKey:selectionKey)
                clearActive()
                error = "Household access ended. Its cached data has been removed."
                return
            }
            members = roster
            while let mutation = pending.first {
                sendingID = mutation.id
                struct Body: Encodable {
                    let p_id: UUID; let p_household_id: UUID; let p_kind: RecordKind
                    let p_payload: SharedFields; let p_base_version: Int64; let p_deleted: Bool; let p_mutation_id: UUID
                }
                let record = mutation.record
                let result: MutationResult
                do {
                    result = try await backend.rpc("mutate_record", Body(p_id:record.id,p_household_id:active.id,p_kind:record.kind,p_payload:record.payload,p_base_version:mutation.baseVersion,p_deleted:record.deleted,p_mutation_id:mutation.id))
                } catch BackendError.response(let status,let message) where (400..<500).contains(status) && status != 401 && status != 429 {
                    guard generation == requestGeneration else { return }
                    let draft = pending.last { $0.record.id == record.id }?.record ?? record
                    conflicts.append(RecordConflict(draft:draft,remote:nil))
                    pending.removeAll { $0.record.id == record.id }
                    error = message
                    try persist()
                    continue
                }
                guard generation == requestGeneration else { return }
                if result.conflict {
                    let latestDraft = pending.last { $0.record.id == record.id }?.record ?? record
                    conflicts.append(RecordConflict(draft:latestDraft,remote:result.record))
                    pending.removeAll { $0.record.id == record.id }
                } else {
                    pending.removeAll { $0.id == mutation.id }
                    if !pending.contains(where: { $0.record.id == record.id }), let saved = result.record { replace(saved) }
                    if let next = result.nextRecord { replace(next) }
                }
                try persist()
            }
            var fetched: [SharedRecord] = []
            var offset = 0
            while true {
                let page: [SharedRecord] = try await backend.get("rest/v1/household_records?household_id=eq.\(active.id)&select=*&order=id&limit=500&offset=\(offset)")
                guard generation == requestGeneration else { return }
                fetched += page
                if page.count < 500 { break }
                offset += page.count
            }
            // Preserve any edits created while fetch requests were in flight.
            let protected = Set(pending.map { $0.record.id } + conflicts.map(\.id))
            records = fetched.filter { !protected.contains($0.id) } + records.filter { protected.contains($0.id) }
            let activity: [SharedActivity] = try await backend.get("rest/v1/household_activity?household_id=eq.\(active.id)&select=*&order=id.desc&limit=100")
            guard generation == requestGeneration else { return }
            activities = activity
            if isOwner {
                let invitations: [SharedInvite] = try await backend.get("rest/v1/household_invites?household_id=eq.\(active.id)&select=*&order=expires_at.desc")
                guard generation == requestGeneration else { return }
                invites = invitations
            } else { invites = [] }
            lastSynced = Date()
            error = nil
            try persist()
        } catch { if generation == requestGeneration { self.error = error.localizedDescription } }
    }

    func exportData() throws -> Data {
        try SharedCoding.encoder().encode(Cache(household:household,members:members,records:records,activities:activities,pending:pending,conflicts:conflicts.map { CachedConflict(draft:$0.draft,remote:$0.remote) }))
    }

    func reset() {
        clearActive()
        households = []
        isLocal = false
        UserDefaults.standard.set(false, forKey: "hh.localMode")
    }
    func deleteLocalHousehold() throws {
        if let household { try FileManager.default.removeItem(at: cacheURL(household.id)) }
        reset()
    }

    private func replace(_ record: SharedRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
        else { records.append(record) }
    }
    private func clearActive() {
        generation = UUID()
        household = nil; records = []; members = []; activities = []; invites = []; pending = []; conflicts = []
        isSyncing = false; lastSynced = nil; sendingID = nil; error = nil
        cacheUnreadable = false
    }

    private struct CachedConflict: Codable { let draft: SharedRecord; let remote: SharedRecord? }
    private struct Cache: Codable {
        let household: SharedHousehold?; let members: [SharedMember]; let records: [SharedRecord]
        let activities: [SharedActivity]; let pending: [PendingMutation]; let conflicts: [CachedConflict]
    }
    private func cacheURL(_ householdID: UUID) -> URL {
        let base = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("HouseholdOS",isDirectory:true)
        return base.appendingPathComponent("\(userID)-\(householdID).json")
    }
    private func persist() throws {
        guard let household else { return }
        guard !cacheUnreadable else { throw BackendError.server("Saved offline data needs recovery before it can be overwritten. The original cache has been preserved.") }
        let url = cacheURL(household.id)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try exportData().write(to:url,options:options)
    }
    private func loadCache(_ id: UUID) {
        let url = cacheURL(id)
        guard FileManager.default.fileExists(atPath:url.path) else { return }
        do {
            let cache = try SharedCoding.decoder().decode(Cache.self,from:Data(contentsOf:url))
            household = cache.household; members = cache.members; records = cache.records; activities = cache.activities; pending = cache.pending
            conflicts = cache.conflicts.map { RecordConflict(draft:$0.draft,remote:$0.remote) }
        } catch { cacheUnreadable = true; self.error = "Saved household data could not be read. The original cache is preserved for recovery." }
    }
    private var selectionKey: String { "hh.selection.\(userID)" }
    private func saveSelection() {
        if let household, let data = try? SharedCoding.encoder().encode(household) { UserDefaults.standard.set(data,forKey:selectionKey) }
    }
    private func loadCachedSelection() {
        guard let data = UserDefaults.standard.data(forKey:selectionKey), let selected = try? SharedCoding.decoder().decode(SharedHousehold.self,from:data) else { return }
        household = selected
        loadCache(selected.id)
    }

    private func createLocalRecurrence(old: SharedRecord?, new: SharedRecord) {
        guard new.kind == .task || new.kind == .bill, new.isFinished, old?.isFinished != true, !new.deleted,
              let due = new.payload.dueAt, new.payload.repeatRule != .none,
              !records.contains(where: { $0.payload.previousID == new.id }) else { return }
        var calendar = Calendar(identifier:.gregorian)
        calendar.timeZone = TimeZone(identifier:household?.timezone ?? "") ?? .current
        let component: Calendar.Component
        switch new.payload.repeatRule { case .daily: component = .day; case .weekly: component = .weekOfYear; case .monthly: component = .month; case .yearly: component = .year; case .none: return }
        guard var next = calendar.date(byAdding:component,value:1,to:due) else { return }
        if new.payload.repeatRule == .monthly, let anchor = new.payload.anchorDay, let days = calendar.range(of:.day,in:.month,for:next) {
            next = calendar.date(bySetting:.day,value:min(anchor,days.count),of:next) ?? next
        }
        var fields = new.payload
        fields.dueAt = next; fields.completed = false; fields.completedAt = nil; fields.paid = false; fields.paidByID = nil; fields.paidAt = nil; fields.previousID = new.id
        for i in fields.subtasks.indices { fields.subtasks[i].completed = false }
        let rotation = fields.rotation.filter { id in members.contains { $0.userID == id } }
        if !rotation.isEmpty {
            let current = rotation.firstIndex { $0 == fields.assigneeID } ?? -1
            fields.assigneeID = rotation[(current+1) % rotation.count]
        }
        records.append(SharedRecord(id:UUID(),householdID:new.householdID,kind:new.kind,payload:fields,version:1,deleted:false,updatedBy:userID,updatedAt:Date()))
    }
}
