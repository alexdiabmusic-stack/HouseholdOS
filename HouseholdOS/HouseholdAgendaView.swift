import SwiftUI
import UniformTypeIdentifiers

private struct AgendaDocument: FileDocument {
    static var readableContentTypes:[UTType] { [UTType(filenameExtension:"ics") ?? .plainText] }
    var data:Data
    init(data:Data) { self.data = data }
    init(configuration:ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration:WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents:data) }
}

struct HouseholdAgendaView: View {
    @Environment(HouseholdStore.self) private var store
    @State private var selected = Date()
    @State private var editor:RecordEditorRequest?
    @State private var exporting = false
    @State private var error:String?
    private var scheduled:[SharedRecord] {
        (store.visible(.task)+(store.canManageMoney ? store.visible(.bill) : [])).filter { !$0.isFinished && $0.payload.dueAt != nil }
    }
    private var calendar:Calendar {
        var result = Calendar(identifier:.gregorian)
        result.timeZone = TimeZone(identifier:store.household?.timezone ?? "") ?? .current
        return result
    }
    var body: some View {
        List {
            Section {
                DatePicker("Day",selection:$selected,displayedComponents:.date).datePickerStyle(.graphical)
                    .environment(\.calendar,calendar).environment(\.timeZone,calendar.timeZone)
            }
            Section("Due on this day") {
                let events = scheduled.filter { calendar.isDate($0.payload.dueAt ?? .distantPast,inSameDayAs:selected) }
                ForEach(events) { record in SharedRecordRow(record:record) { editor = RecordEditorRequest(kind:record.kind,record:record) } }
                if events.isEmpty { Text("Nothing scheduled.").foregroundStyle(.secondary) }
            }
            Section {
                Button("Export calendar snapshot") { exporting = true }.disabled(scheduled.isEmpty)
                Text("Export current task and bill dates to your calendar. This snapshot does not sync later changes.").font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Agenda").householdListStyle()
        .sheet(item:$editor) { SharedRecordEditor(request:$0) }
        .fileExporter(isPresented:$exporting,document:AgendaDocument(data:CalendarSnapshot.data(records:scheduled)),contentType:AgendaDocument.readableContentTypes[0],defaultFilename:"HouseholdOS-agenda.ics") { result in if case .failure(let error) = result { self.error = error.localizedDescription } }
    }
}
