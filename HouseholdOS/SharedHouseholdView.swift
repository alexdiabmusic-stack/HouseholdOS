import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct HouseholdExport: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data:Data) { self.data = data }
    init(configuration:ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration:WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents:data) }
}

struct SharedHouseholdView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(BackendClient.self) private var backend
    @Environment(ReminderService.self) private var reminders
    @Environment(\.openURL) private var openURL
    @State private var showInvite = false
    @State private var showSetup = false
    @State private var editor: RecordEditorRequest?
    @State private var export: HouseholdExport?
    @State private var showExport = false
    @State private var error: String?
    @State private var leaving = false
    @State private var deleting = false
    @State private var signOut = false
    @State private var memberToRemove: SharedMember?
    @State private var memberToOwn: SharedMember?
    @State private var busy = false
    @State private var reconnect = false
    var body: some View {
        List {
            HouseholdSyncSection()
            Section(store.household?.name ?? "Household") {
                ForEach(store.members) { member in
                    HStack {
                        VStack(alignment:.leading,spacing:4) {
                            Text(member.displayName + (member.userID == store.userID ? " (you)" : ""))
                            Text(member.role.capitalized).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.isOwner && !store.isLocal && member.userID != store.userID {
                            Menu("Manage") {
                                if member.role == "member" { Button("Make owner") { memberToOwn = member } }
                                Button("Remove member",role:.destructive) { memberToRemove = member }
                            }
                        }
                    }
                }
                if !store.isLocal {
                    if store.isOwner { Button("Invite a member") { showInvite = true } }
                    Button("Switch, create, or join a household") { showSetup = true }
                    if !store.isOwner { Button("Leave household",role:.destructive) { leaving = true } }
                }
            }
            if store.isOwner && !store.isLocal {
                Section("Invitations") {
                    ForEach(store.invites.filter { $0.acceptedBy == nil && $0.revokedAt == nil && $0.expiresAt > Date() }) { invite in
                        VStack(alignment:.leading,spacing:6) {
                            Text(invite.invitedEmail)
                            ShareLink("Share invitation",item:invite.url)
                            Button("Revoke invitation",role:.destructive) { run { try await store.revoke(invite) } }
                        }
                    }
                }
            }
            Section {
                Toggle("Task and bill reminders",isOn:Binding(get:{reminders.enabled},set:{enabled in
                    if enabled { Task { await reminders.requestPermission(); await reschedule() } }
                    else { reminders.enabled = false; Task { await reminders.clear() } }
                }))
                if reminders.permission == .denied {
                    Button("Open notification settings") { if let url = URL(string:UIApplication.openSettingsURLString) { openURL(url) } }
                }
                Text("Reminders are scheduled on this device after it syncs. Open the app to receive the latest household changes.").font(.footnote).foregroundStyle(.secondary)
                Toggle("Quiet hours",isOn:Binding(get:{reminders.quietHours},set:{reminders.quietHours = $0; Task { await reschedule() } }))
                if reminders.quietHours {
                    Picker("Quiet from",selection:Binding(get:{reminders.quietStart},set:{reminders.quietStart = $0; Task { await reschedule() } })) {
                        ForEach(0..<24) { hour in Text(String(format:"%02d:00",hour)).tag(hour) }
                    }
                    Picker("Until",selection:Binding(get:{reminders.quietEnd},set:{reminders.quietEnd = $0; Task { await reschedule() } })) {
                        ForEach(0..<24) { hour in Text(String(format:"%02d:00",hour)).tag(hour) }
                    }
                    Text("Uses household time. Reminders during quiet hours move to the next allowed morning; some may arrive after their due time.").font(.footnote).foregroundStyle(.secondary)
                }
                if let error = reminders.error { Text(error).foregroundStyle(.red) }
            } header: { Text("Reminders") }
            Section("Home records") {
                NavigationLink("Household agenda") { HouseholdAgendaView() }
                NavigationLink("Appliances, manuals, and warranties") { SharedAssetsView() }
                NavigationLink("Import existing on-device data") { LegacyImportView() }
            }
            if !store.isLocal { Section { NavigationLink("Household plan") { HouseholdPlanView() } } }
            Section("Your data") {
                Button("Export this household") { do { export = HouseholdExport(data:try store.exportData()); showExport = true } catch { self.error = error.localizedDescription } }
                NavigationLink("How your data is used") { HouseholdPrivacyView() }
                if store.isLocal {
                    Button("Connect a shared account") { signOut = true }
                    Button("Delete on-device household",role:.destructive) { deleting = true }
                } else {
                    Button("Reconnect your account") { reconnect = true }
                    Button("Sign out",role:.destructive) { signOut = true }
                    Button("Delete my account",role:.destructive) { deleting = true }
                }
            }
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Household").householdListStyle()
        .sheet(isPresented:$showInvite) { InviteMemberView() }
        .sheet(isPresented:$showSetup) { NavigationStack { HouseholdSetupView() } }
        .sheet(isPresented:$reconnect) { AccountReconnectView() }
        .fileExporter(isPresented:$showExport,document:export,contentType:.json,defaultFilename:"HouseholdOS-export") { result in if case .failure(let error) = result { self.error = error.localizedDescription } }
        .confirmationDialog("Leave this household?",isPresented:$leaving,titleVisibility:.visible) {
            Button("Leave household",role:.destructive) { if let me = store.myMember { run { try await store.remove(me); await reminders.clear() } } }
        }
        .confirmationDialog("Sign out of this household?",isPresented:$signOut,titleVisibility:.visible) {
            Button("Sign out",role:.destructive) {
                guard store.pending.isEmpty && store.conflicts.isEmpty else { error = "Sync or export pending changes and resolve conflicts before signing out."; return }
                run { await reminders.clear(); await backend.signOut(); store.reset() }
            }
        } message: { Text("On-device household data is preserved. Shared data stays with your household.") }
        .confirmationDialog(store.isLocal ? "Delete this on-device household?" : "Permanently delete your account?",isPresented:$deleting,titleVisibility:.visible) {
            Button("Delete",role:.destructive) { run {
                if store.isLocal { try store.deleteLocalHousehold() }
                else { let _: JSONValue = try await backend.function("account/delete",[String:String]()); try store.removeAccountCache(); await backend.signOut(); store.reset() }
                await reminders.clear()
            }}
        } message: { Text(store.isLocal ? "Export first if you want a copy." : "Transfer household ownership before deleting your account. Shared household records remain for other members.") }
        .confirmationDialog("Remove this member?",isPresented:Binding(get:{memberToRemove != nil},set:{if !$0 { memberToRemove = nil }}),titleVisibility:.visible) {
            Button("Remove",role:.destructive) { if let member = memberToRemove { run { try await store.remove(member) } }; memberToRemove = nil }
        }
        .confirmationDialog("Transfer household ownership?",isPresented:Binding(get:{memberToOwn != nil},set:{if !$0 { memberToOwn = nil }}),titleVisibility:.visible) {
            Button("Transfer ownership") { if let member = memberToOwn { run { try await store.transferOwnership(to:member) } }; memberToOwn = nil }
        } message: { Text("The new owner will manage invitations and membership. You'll remain an adult member.") }
    }
    private func run(_ action:@escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription } }
    }
    private func reschedule() async { await reminders.reconcile(records:store.records,userID:store.userID,timezone:store.household?.timezone ?? TimeZone.current.identifier) }
}

struct InviteMemberView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var role = "member"
    @State private var invite: SharedInvite?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                if let invite {
                    Section("Invitation ready") {
                        Text("Share this with \(invite.invitedEmail). They need to sign in using that verified email address.")
                        ShareLink("Share invitation",item:invite.url)
                        Text(invite.token).font(.caption.monospaced()).textSelection(.enabled)
                        Text("Expires \(invite.expiresAt.formatted(date:.abbreviated,time:.shortened))").font(.footnote)
                    }
                } else {
                    Section {
                        TextField("Their email",text:$email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Picker("Role",selection:$role) { Text("Adult member").tag("member"); Text("Child (no bill access)").tag("child") }
                        Button("Create invitation") {
                            busy = true
                            Task { defer { busy = false }; do { invite = try await store.invite(email:email,role:role) } catch { self.error = error.localizedDescription } }
                        }.disabled(busy || email.isEmpty)
                    } footer: { Text("The app creates an invitation for you to share. Sign-up verification emails are sent separately by Supabase.") }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("Invite a member").toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct SharedAssetsView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var editor: RecordEditorRequest?
    var body: some View {
        List {
            ForEach(store.visible(.asset)) { asset in
                Section(asset.payload.title) {
                    if !asset.payload.notes.isEmpty { Text(asset.payload.notes) }
                    if let raw = asset.payload.attachmentURL, let url = URL(string:raw), url.scheme == "https" { Link("Open manual or receipt",destination:url) }
                    Button("Edit") { editor = RecordEditorRequest(kind:.asset,record:asset) }
                }
            }
            if store.visible(.asset).isEmpty { ContentUnavailableView("Keep home records together",systemImage:"archivebox",description:Text("Save appliance details, warranty dates, and links to manuals or receipts.")) }
        }.navigationTitle("Home records").toolbar { Button("Add",systemImage:"plus") { editor = RecordEditorRequest(kind:.asset) } }
            .sheet(item:$editor) { SharedRecordEditor(request:$0) }
    }
}

struct LegacyImportView: View {
    @Environment(HouseholdStore.self) private var store
    @Query private var lists: [ShoppingList]
    @Query private var tasks: [HouseholdTask]
    @Query private var maintenance: [MaintenanceTask]
    @State private var error: String?
    @State private var imported = false
    private var importKey: String { "hh.imported.\(store.userID).\(store.household?.id.uuidString ?? "")" }
    var body: some View {
        Form {
            Section {
                Text("Import copies of \(lists.count) lists, \(tasks.count) routines, and \(maintenance.count) maintenance records into this household. The original records are preserved.")
                Text("This shares the imported data with everyone in the selected household.").font(.footnote).foregroundStyle(.secondary)
                if store.hasSavedLocalHousehold {
                    Button("Import saved on-device household") { do { try store.importSavedLocalHousehold() } catch { self.error = error.localizedDescription } }
                }
                Button(imported || UserDefaults.standard.bool(forKey:importKey) ? "Already imported here" : "Import original SwiftData records") { performImport() }
                    .disabled(imported || UserDefaults.standard.bool(forKey:importKey))
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Import local data")
    }
    private func performImport() {
        do {
            for list in lists {
                var fields = SharedFields(title:list.name)
                fields.notes = "Imported from this device"
                let record = try store.importRecord(sourceKey:"legacy:\(list.persistentModelID)",kind:.list,fields:fields)
                for item in list.items {
                    var itemFields = SharedFields(title:item.name)
                    itemFields.parentID = record.id; itemFields.quantity = item.quantity; itemFields.completed = item.isChecked
                    try store.importRecord(sourceKey:"legacy:\(item.persistentModelID)",kind:.item,fields:itemFields)
                }
            }
            for task in tasks {
                var fields = SharedFields(title:task.name)
                fields.completed = task.isCompletedToday
                fields.notes = "Imported routine. Set a due date and repeat schedule to continue it."
                try store.importRecord(sourceKey:"legacy:\(task.persistentModelID)",kind:.task,fields:fields)
            }
            for task in maintenance {
                var fields = SharedFields(title:task.name)
                fields.notes = task.notes; fields.dueAt = task.dueDate; fields.completed = task.isComplete; fields.completedAt = task.completedDate
                try store.importRecord(sourceKey:"legacy:\(task.persistentModelID)",kind:.task,fields:fields)
            }
            UserDefaults.standard.set(true,forKey:importKey); imported = true
        } catch { self.error = error.localizedDescription }
    }
}

struct HouseholdPrivacyView: View {
    var body: some View {
        List {
            Section("Shared household data") { Text("Lists, tasks, and home records are shared with household members. Bills are available to adult members. Owners manage invitations and membership.") }
            Section("Private bank data") { Text("Only the person who connects a bank can view its account and transaction data. Provider credentials stay on the backend. You can disconnect your banks in Money.") }
            Section("On your device") { Text("A cache keeps your household available offline. Sign-in tokens are kept in the device Keychain. Export your household from Household → Your data.") }
            Section("Email verification") { Text("Your email must be confirmed before you can create or join a shared household. This test build uses Supabase's limited sender for project-team addresses.") }
            Section("Account deletion") { Text("Transfer ownership before deleting an owner account. Shared records remain with the household; your private bank data and membership are removed.") }
        }.navigationTitle("Your data")
    }
}

struct AccountReconnectView: View {
    @Environment(BackendClient.self) private var backend
    @Environment(HouseholdStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Text(backend.session?.user.email ?? "Your account")
                SecureField("Password",text:$password).textContentType(.password)
                Button("Reconnect") {
                    busy = true
                    Task { defer { busy = false }; do {
                        try await backend.signIn(email:backend.session?.user.email ?? "",password:password)
                        await store.sync(); dismiss()
                    } catch { self.error = error.localizedDescription } }
                }.disabled(busy || password.isEmpty)
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("Reconnect account").toolbar { Button("Cancel") { dismiss() } }
        }
    }
}
