import SwiftUI

struct SharedRecordEditor: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: RecordEditorRequest
    @State private var fields: SharedFields
    @State private var hasDueDate: Bool
    @State private var dueAt: Date
    @State private var amount = ""
    @State private var splitEvenly = false
    @State private var rotate = false
    @State private var error: String?
    @State private var deleting = false
    init(request: RecordEditorRequest) {
        self.request = request
        var initial = request.record?.payload ?? SharedFields(title:"")
        initial.parentID = request.parentID ?? initial.parentID
        _fields = State(initialValue:initial)
        _rotate = State(initialValue:!initial.rotation.isEmpty)
        _hasDueDate = State(initialValue:initial.dueAt != nil)
        _dueAt = State(initialValue:initial.dueAt ?? Calendar.current.date(bySettingHour:9,minute:0,second:0,of:Date().addingTimeInterval(86400)) ?? Date())
        if initial.amountCents > 0 {
            let formatter = NumberFormatter(); formatter.numberStyle = .decimal; formatter.usesGroupingSeparator = false; formatter.minimumFractionDigits = 2; formatter.maximumFractionDigits = 2
            _amount = State(initialValue:formatter.string(from:NSDecimalNumber(value:initial.amountCents).dividing(by:100)) ?? "")
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField(request.kind == .item ? "Item" : "Name",text:$fields.title)
                    if request.kind == .item { TextField("Quantity and units",text:$fields.quantity); TextField("Store or aisle",text:$fields.aisle) }
                    TextField("Notes",text:$fields.notes,axis:.vertical).lineLimit(3...8)
                }
                if request.kind == .task || request.kind == .bill {
                    Section("Responsibility and schedule") {
                        Picker("Assigned to",selection:$fields.assigneeID) {
                            Text("Unassigned").tag(nil as UUID?)
                            ForEach(store.members) { member in Text(member.displayName).tag(Optional(member.userID)) }
                        }
                        Toggle("Due date",isOn:$hasDueDate)
                        if hasDueDate {
                            DatePicker("Due",selection:$dueAt,displayedComponents:[.date,.hourAndMinute])
                            Picker("Repeat",selection:$fields.repeatRule) { ForEach(RepeatRule.allCases) { rule in Text(rule.label).tag(rule) } }
                            Text("Repeating tasks and bills create a new occurrence when completed.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if request.kind == .task {
                    Section("Checklist") {
                        ForEach($fields.subtasks) { $subtask in
                            HStack {
                                Toggle("Completed",isOn:$subtask.completed).labelsHidden().accessibilityLabel("Subtask completed")
                                TextField("Subtask",text:$subtask.title)
                            }
                        }.onDelete { fields.subtasks.remove(atOffsets:$0) }
                        Button("Add subtask") { fields.subtasks.append(SharedSubtask(title:"")) }.disabled(fields.subtasks.count>=30)
                    }
                    if hasDueDate && fields.repeatRule != .none {
                        Section { Toggle("Rotate among household members",isOn:$rotate) } footer: { Text("Each new occurrence is assigned to the next member in the rotation.") }
                    }
                }
                if request.kind == .bill {
                    Section {
                        TextField("Amount",text:$amount).keyboardType(.decimalPad)
                        TextField("Currency",text:$fields.currency).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        Toggle("Split evenly among adult members",isOn:$splitEvenly)
                        ForEach(store.members.filter { $0.role != "child" }) { member in
                            if let share = fields.shares[member.userID.uuidString] { LabeledContent(member.displayName,value:MoneyAmount.display(share,currency:fields.currency)) }
                        }
                    } header: { Text("Amount and household shares") } footer: { Text("Payment records are entered by your household and do not initiate transfers.") }
                }
                if request.kind == .asset {
                    Section("Documents") {
                        TextField("Manual or receipt URL (https)",text:Binding(get:{fields.attachmentURL ?? ""},set:{fields.attachmentURL = $0.isEmpty ? nil : $0})).keyboardType(.URL).textInputAutocapitalization(.never)
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
                if request.record != nil { Section { Button("Delete",role:.destructive) { deleting = true } } }
            }.navigationTitle(request.record == nil ? "New \(request.kind.rawValue)" : "Edit \(request.kind.rawValue)")
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button("Save",action:save).disabled(fields.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) }
            }
            .confirmationDialog("Delete this \(request.kind.rawValue)?",isPresented:$deleting,titleVisibility:.visible) {
                Button("Delete",role:.destructive) { do { if let record = request.record { try store.delete(record) }; dismiss() } catch { self.error = error.localizedDescription } }
            }
        }
    }
    private func save() {
        fields.title = fields.title.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !fields.title.isEmpty, fields.title.count <= 160 else { error = "Use a name between 1 and 160 characters."; return }
        fields.dueAt = hasDueDate ? dueAt : nil
        if !hasDueDate { fields.repeatRule = .none }
        fields.subtasks = fields.subtasks.filter { !$0.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
        fields.rotation = rotate && fields.repeatRule != .none ? store.members.map(\.userID).sorted { $0.uuidString < $1.uuidString } : []
        if let assignee = fields.assigneeID, !store.members.contains(where: { $0.userID == assignee }) { fields.assigneeID = nil }
        var calendar = Calendar(identifier:.gregorian)
        calendar.timeZone = TimeZone(identifier:store.household?.timezone ?? "") ?? .current
        if fields.anchorDay == nil || request.record?.payload.dueAt != fields.dueAt { fields.anchorDay = calendar.component(.day,from:dueAt) }
        if request.kind == .bill {
            guard let cents = MoneyAmount.cents(amount) else { error = "Enter a positive amount with no more than two decimal places."; return }
            fields.amountCents = cents; fields.currency = fields.currency.uppercased()
            guard fields.currency.count == 3, fields.currency.allSatisfy({ $0.isASCII && $0.isLetter }) else { error = "Enter a three-letter currency code."; return }
            if splitEvenly {
                let adults = store.members.filter { $0.role != "child" }.sorted { $0.userID.uuidString < $1.userID.uuidString }
                guard !adults.isEmpty else { error = "An adult household member is required."; return }
                fields.shares = [:]
                for (index,adult) in adults.enumerated() { fields.shares[adult.userID.uuidString] = cents / Int64(adults.count) + (Int64(index) < cents % Int64(adults.count) ? 1 : 0) }
            }
        }
        if let url = fields.attachmentURL, URL(string:url)?.scheme != "https" { error = "Use a secure https document link."; return }
        do {
            if var record = request.record { record.payload = fields; try store.save(record) }
            else { try store.add(request.kind,fields:fields) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
