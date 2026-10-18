import SwiftUI

struct RecordEditorRequest: Identifiable {
    let id = UUID()
    var kind: RecordKind
    var record: SharedRecord?
    var parentID: UUID?
}

struct HouseholdSyncSection: View {
    @Environment(HouseholdStore.self) private var store
    var body: some View {
        Section {
            HStack {
                Label(store.syncLabel,systemImage:store.isLocal ? "iphone" : "arrow.triangle.2.circlepath").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                if !store.isLocal { Button("Refresh") { Task { await store.sync() } }.font(.footnote).disabled(store.isSyncing) }
            }
            if let error = store.error { Text(error).font(.footnote).foregroundStyle(.red) }
            if !store.conflicts.isEmpty { NavigationLink("Review conflicting edits") { ConflictReviewView() } }
        }
    }
}

struct SharedTodayView: View {
    @Environment(HouseholdStore.self) private var store
    @State private var editor: RecordEditorRequest?
    private var urgent: [SharedRecord] {
        (store.visible(.task) + (store.canManageMoney ? store.visible(.bill) : []))
            .filter { !$0.isFinished && ($0.payload.dueAt ?? .distantFuture) < Date().addingTimeInterval(3*86400) }
            .sorted { ($0.payload.dueAt ?? .distantFuture) < ($1.payload.dueAt ?? .distantFuture) }
    }
    var body: some View {
        List {
            Section {
                Text(Date(),format:.dateTime.weekday(.wide).month().day()).font(.subheadline).foregroundStyle(.secondary)
                Text(store.household?.name ?? "Your household").font(.title2.bold())
                Text(store.isLocal ? "On this device" : "\(store.members.count) people, one household").foregroundStyle(.secondary)
                HStack {
                    Button { editor = RecordEditorRequest(kind:.list) } label: { Label("List",systemImage:"plus") }
                    Button { editor = RecordEditorRequest(kind:.task) } label: { Label("Task",systemImage:"plus") }
                    if store.canManageMoney { Button { editor = RecordEditorRequest(kind:.bill) } label: { Label("Bill",systemImage:"plus") } }
                }.buttonStyle(.bordered)
            }
            HouseholdSyncSection()
            Section("Needs attention") {
                if urgent.isEmpty { Text("No tasks or bills due in the next three days.").foregroundStyle(.secondary) }
                ForEach(urgent) { record in SharedRecordRow(record:record) { editor = RecordEditorRequest(kind:record.kind,record:record) } }
            }
            Section("Shopping") {
                ForEach(store.visible(.list)) { list in
                    NavigationLink { SharedListDetailView(listID:list.id) } label: {
                        LabeledContent(list.payload.title,value:"\(store.visible(.item,parent:list.id).filter { !$0.payload.completed }.count) to get")
                    }
                }
                if store.visible(.list).isEmpty { Button("Create your first grocery list") { editor = RecordEditorRequest(kind:.list) } }
            }
            Section("Recent activity") {
                if store.activities.isEmpty { Text(store.isLocal ? "Shared activity is available in a connected household." : "Your household's updates will appear here.").foregroundStyle(.secondary) }
                ForEach(store.activities.prefix(8)) { event in
                    VStack(alignment:.leading,spacing:4) {
                        Text("\(event.actorName) \(event.action) \(event.title)")
                        Text(event.createdAt,style:.relative).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.navigationTitle("Today").householdListStyle().refreshable { await store.sync() }
            .sheet(item:$editor) { SharedRecordEditor(request:$0) }
    }
}

struct SharedListsView: View {
    @Environment(HouseholdStore.self) private var store
    @State private var editor: RecordEditorRequest?
    @State private var query = ""
    @State private var toDelete: SharedRecord?
    @State private var error: String?
    var body: some View {
        List {
            HouseholdSyncSection()
            Section {
                ForEach(store.visible(.list).filter { query.isEmpty || $0.payload.title.localizedCaseInsensitiveContains(query) }) { list in
                    NavigationLink { SharedListDetailView(listID:list.id) } label: {
                        VStack(alignment:.leading,spacing:4) {
                            Label(list.payload.title,systemImage:"basket")
                            Text("\(store.visible(.item,parent:list.id).filter { !$0.payload.completed }.count) items remaining").font(.caption).foregroundStyle(.secondary)
                            if let shopper = list.payload.shoppingByID { Text("\(store.name(for:shopper)) is shopping").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.swipeActions {
                        Button("Delete",role:.destructive) { toDelete = list }
                        Button("Edit") { editor = RecordEditorRequest(kind:.list,record:list) }.tint(.hhAccent)
                        Button("Reuse") { do { try store.reuseList(list) } catch { self.error = error.localizedDescription } }.tint(.blue)
                    }
                }
                if store.visible(.list).isEmpty { ContentUnavailableView("Your first shared list",systemImage:"basket",description:Text("Add a grocery list, an errand list, or anything your household needs.")) }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Lists").householdListStyle().searchable(text:$query,prompt:"Find a list")
        .toolbar { Button("New list",systemImage:"plus") { editor = RecordEditorRequest(kind:.list) } }
        .sheet(item:$editor) { SharedRecordEditor(request:$0) }
        .confirmationDialog("Delete this list and its items?",isPresented:Binding(get:{toDelete != nil},set:{if !$0 { toDelete = nil }}),titleVisibility:.visible) {
            Button("Delete list",role:.destructive) { if let record = toDelete { do { try store.delete(record) } catch { self.error = error.localizedDescription } }; toDelete = nil }
        }.refreshable { await store.sync() }
    }
}

struct SharedListDetailView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.openURL) private var openURL
    let listID: UUID
    @State private var itemName = ""
    @State private var search = ""
    @State private var editor: RecordEditorRequest?
    @State private var deletedItem: SharedRecord?
    @State private var error: String?
    @State private var busy = false
    @State private var duplicate: SharedRecord?
    @FocusState private var adding: Bool
    private var list: SharedRecord? { store.records.first { $0.id == listID && !$0.deleted } }
    private var items: [SharedRecord] { store.visible(.item,parent:listID).filter { search.isEmpty || $0.payload.title.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        List {
            HouseholdSyncSection()
            if let list {
                Section {
                    HStack {
                        TextField("Add an item",text:$itemName).focused($adding).submitLabel(.done).onSubmit(addItem)
                        Button("Add",systemImage:"plus.circle.fill",action:addItem).labelStyle(.iconOnly).frame(minWidth:44,minHeight:44).disabled(itemName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    }
                    Button(list.payload.shoppingByID == store.userID ? "Finish shopping" : "I'm shopping") {
                        act { var changed = list; changed.payload.shoppingByID = list.payload.shoppingByID == store.userID ? nil : store.userID; try store.save(changed) }
                    }
                    if let shopper = list.payload.shoppingByID { Text("\(store.name(for:shopper)) is shopping").font(.footnote).foregroundStyle(.secondary) }
                }
                Section("To get") {
                    ForEach(items.filter { !$0.payload.completed }) { item in itemRow(item) }
                    if items.filter({ !$0.payload.completed }).isEmpty { Text("Nothing left to get.").foregroundStyle(.secondary) }
                }
                if items.contains(where: { $0.payload.completed }) { Section("Got it") { ForEach(items.filter { $0.payload.completed }) { item in itemRow(item) } } }
                if let deletedItem { Section { Button("Undo deletion of \(deletedItem.payload.title)") { act { try store.duplicate(deletedItem); self.deletedItem = nil } } } }
                if !store.isLocal && items.contains(where: { !$0.payload.completed }) {
                    Section {
                        Button("Shop this list on Instacart") {
                            busy = true; error = nil
                            Task {
                                defer { busy = false }
                                do {
                                    struct Request: Encodable { let list_id: UUID }
                                    struct Result: Decodable { let url: URL }
                                    let result: Result = try await store.backend.function("grocery/list",Request(list_id:listID))
                                    guard result.url.scheme == "https" else { throw BackendError.server("Invalid shopping link.") }
                                    openURL(result.url)
                                } catch { self.error = error.localizedDescription }
                            }
                        }.disabled(busy)
                        Text("Checkout takes place on Instacart. Opening a list does not place an order.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else { ContentUnavailableView("List unavailable",systemImage:"basket",description:Text("It may have been deleted by someone in your household.")) }
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle(list?.payload.title ?? "List").householdListStyle().searchable(text:$search,prompt:"Find an item")
        .toolbar { if let list { Button("Edit list") { editor = RecordEditorRequest(kind:.list,record:list) } } }
        .sheet(item:$editor) { SharedRecordEditor(request:$0) }
        .alert("Already on this list",isPresented:Binding(get:{duplicate != nil},set:{if !$0 { duplicate = nil }})) {
            Button("Use existing item") { if let duplicate { editor = RecordEditorRequest(kind:.item,record:duplicate,parentID:listID) }; itemName = ""; duplicate = nil }
            Button("Add anyway") { insertItem() }
            Button("Cancel",role:.cancel) { duplicate = nil }
        } message: { Text("Edit the existing item to change its quantity, or add another.") }
        .refreshable { await store.sync() }
    }
    private func itemRow(_ item: SharedRecord) -> some View {
        HStack {
            Button { act { try store.toggle(item) } } label: {
                Image(systemName:item.payload.completed ? "checkmark.circle.fill" : "circle").font(.title2).frame(minWidth:44,minHeight:44)
            }.buttonStyle(.borderless).accessibilityLabel(item.payload.completed ? "Mark \(item.payload.title) needed" : "Mark \(item.payload.title) purchased")
            Button { editor = RecordEditorRequest(kind:.item,record:item,parentID:listID) } label: {
                VStack(alignment:.leading,spacing:3) {
                    Text(item.payload.title).strikethrough(item.payload.completed)
                    if !item.payload.quantity.isEmpty { Text(item.payload.quantity).font(.caption).foregroundStyle(.secondary) }
                    if !item.payload.aisle.isEmpty { Text(item.payload.aisle).font(.caption).foregroundStyle(.secondary) }
                }.foregroundStyle(item.payload.completed ? Color.secondary : Color.primary)
            }.buttonStyle(.plain)
        }.swipeActions { Button("Delete",role:.destructive) { act { try store.delete(item); deletedItem = item } } }
        .accessibilityAction(named:Text("Edit")) { editor = RecordEditorRequest(kind:.item,record:item,parentID:listID) }
    }
    private func addItem() {
        let title = itemName.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if let existing = store.visible(.item,parent:listID).first(where: { $0.payload.title.caseInsensitiveCompare(title) == .orderedSame }) { duplicate = existing }
        else { insertItem() }
    }
    private func insertItem() { act { var fields = SharedFields(title:itemName.trimmingCharacters(in:.whitespacesAndNewlines)); fields.parentID = listID; try store.add(.item,fields:fields); itemName = ""; duplicate = nil; adding = true } }
    private func act(_ action: () throws -> Void) { do { try action(); error = nil } catch { self.error = error.localizedDescription } }
}

struct SharedTasksView: View {
    @Environment(HouseholdStore.self) private var store
    @State private var filter = "all"
    @State private var search = ""
    @State private var editor: RecordEditorRequest?
    @State private var showCompleted = false
    private var tasks: [SharedRecord] {
        store.visible(.task).filter { task in
            (showCompleted || !task.isFinished) && (filter == "all" || (filter == "mine" ? task.payload.assigneeID == store.userID : task.payload.assigneeID == nil)) && (search.isEmpty || task.payload.title.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        List {
            HouseholdSyncSection()
            Section {
                Picker("Show tasks",selection:$filter) { Text("Everyone").tag("all"); Text("Mine").tag("mine"); Text("Unassigned").tag("unassigned") }.pickerStyle(.segmented)
                Toggle("Show completed",isOn:$showCompleted)
            }
            Section("Household tasks") {
                ForEach(tasks) { task in SharedRecordRow(record:task) { editor = RecordEditorRequest(kind:.task,record:task) } }
                if tasks.isEmpty { ContentUnavailableView("Room to breathe",systemImage:"checkmark.circle",description:Text("Add a chore, a one-off task, or a maintenance reminder.")) }
            }
        }.navigationTitle("Tasks").householdListStyle().searchable(text:$search,prompt:"Find a task")
        .toolbar { Button("Add task",systemImage:"plus") { editor = RecordEditorRequest(kind:.task) } }
        .sheet(item:$editor) { SharedRecordEditor(request:$0) }.refreshable { await store.sync() }
    }
}

struct SharedRecordRow: View {
    @Environment(HouseholdStore.self) private var store
    let record: SharedRecord
    let onEdit: () -> Void
    @State private var error: String?
    @State private var confirmPayment = false
    @State private var confirmDeletion = false
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            HStack {
                Button { if record.kind == .bill { confirmPayment = true } else { toggle() } } label: {
                    Image(systemName:record.isFinished ? "checkmark.circle.fill" : "circle").font(.title2).frame(minWidth:44,minHeight:44)
                }.buttonStyle(.borderless)
                .accessibilityLabel(record.kind == .bill ? "Record payment for \(record.payload.title)" : "Toggle completion of \(record.payload.title)")
                Button(action:onEdit) {
                    VStack(alignment:.leading,spacing:4) {
                        Text(record.payload.title).strikethrough(record.isFinished).foregroundStyle(.primary)
                        if record.kind == .bill { Text(MoneyAmount.display(record.payload.amountCents,currency:record.payload.currency)).font(.subheadline).foregroundStyle(.primary) }
                        if let due = record.payload.dueAt { Text(due,format:.dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(record.isOverdue ? Color.red : Color.secondary) }
                        Text(record.kind == .bill && record.payload.paid ? "Payment recorded by \(store.name(for:record.payload.paidByID))" : store.name(for:record.payload.assigneeID)).font(.caption).foregroundStyle(.secondary)
                        if record.payload.repeatRule != .none { Text(record.payload.repeatRule.label).font(.caption).foregroundStyle(.secondary) }
                        if !record.payload.subtasks.isEmpty { Text("\(record.payload.subtasks.filter(\.completed).count) of \(record.payload.subtasks.count) steps complete").font(.caption).foregroundStyle(.secondary) }
                    }
                }.buttonStyle(.plain)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }.swipeActions {
            Button("Delete",role:.destructive) { confirmDeletion = true }
            Button("Edit",action:onEdit).tint(.hhAccent)
        }
        .confirmationDialog(record.payload.paid ? "Remove this payment record?" : "Record this bill as paid?",isPresented:$confirmPayment,titleVisibility:.visible) {
            Button(record.payload.paid ? "Remove payment record" : "I paid this bill") { toggle() }
        } message: { Text("This records a household payment. It does not move money or confirm bank settlement.") }
        .confirmationDialog("Delete \(record.payload.title)?",isPresented:$confirmDeletion,titleVisibility:.visible) {
            Button("Delete",role:.destructive) { do { try store.delete(record) } catch { self.error = error.localizedDescription } }
        }.accessibilityAction(named:Text("Edit"),onEdit)
    }
    private func toggle() { do { try store.toggle(record) } catch { self.error = error.localizedDescription } }
}

struct ConflictReviewView: View {
    @Environment(HouseholdStore.self) private var store
    @State private var error: String?
    var body: some View {
        List {
            Section { Text("Someone changed the same record while your edit was waiting. Review both versions before choosing.") }
            ForEach(store.conflicts) { conflict in
                Section(conflict.draft.payload.title) {
                    Text("Your version: \(conflict.draft.payload.title)")
                    Text(conflict.draft.payload.notes).foregroundStyle(.secondary)
                    Text("Latest version: \(conflict.remote?.deleted == true ? "Deleted" : conflict.remote?.payload.title ?? "Unavailable")")
                    if let remote = conflict.remote { Text(remote.payload.notes).foregroundStyle(.secondary) }
                    Button("Keep my version") { resolve(conflict,keep:true) }
                    Button("Use latest version") { resolve(conflict,keep:false) }
                }
            }
            if store.conflicts.isEmpty { Text("No edit conflicts to review.") }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Review edits")
    }
    private func resolve(_ conflict: RecordConflict,keep: Bool) { do { try store.resolve(conflict,keepDraft:keep) } catch { self.error = error.localizedDescription } }
}

extension View {
    func householdListStyle() -> some View { self.scrollContentBackground(.hidden).background(Color.hhBg) }
}
