import SwiftUI
#if canImport(LinkKit)
import LinkKit
#endif

struct BankAccountSummary: Codable, Identifiable {
    let id: String
    let name: String
    let institution: String
    let type: String
    let currency: String
    let balanceCents: Int64?
    let availableCents: Int64?
    let mask: String?
}
struct BankTransactionSummary: Codable, Identifiable {
    let id: String
    let accountID: String
    let name: String
    let date: String
    let amountCents: Int64
    let currency: String
    let pending: Bool
    let category: String
}
struct BankSnapshot: Codable {
    let accounts: [BankAccountSummary]
    let transactions: [BankTransactionSummary]
    let environment: String
    let refreshedAt: Date?
}

struct SharedMoneyView: View {
    @SwiftUI.Environment(HouseholdStore.self) private var store
    @State private var editor: RecordEditorRequest?
    @State private var showPaid = false
    private var unpaid: [SharedRecord] { store.visible(.bill).filter { !$0.payload.paid } }
    var body: some View {
        List {
            HouseholdSyncSection()
            if store.canManageMoney {
                Section("Household bills") {
                    ForEach(unpaid) { bill in SharedRecordRow(record:bill) { editor = RecordEditorRequest(kind:.bill,record:bill) } }
                    if unpaid.isEmpty { Text("No unpaid bills recorded.").foregroundStyle(.secondary) }
                    Button("Add a bill") { editor = RecordEditorRequest(kind:.bill) }
                }
                Section {
                    Toggle("Show payment records",isOn:$showPaid)
                    if showPaid {
                        ForEach(store.visible(.bill).filter { $0.payload.paid }) { bill in SharedRecordRow(record:bill) { editor = RecordEditorRequest(kind:.bill,record:bill) } }
                    }
                } footer: { Text("These are your household's records. Marking a bill paid does not initiate or verify a bank transfer.") }
                Section("Your shares") {
                    ForEach(unpaid.filter { $0.payload.shares[store.userID.uuidString] != nil }) { bill in
                        LabeledContent(bill.payload.title,value:MoneyAmount.display(bill.payload.shares[store.userID.uuidString] ?? 0,currency:bill.payload.currency))
                    }
                    if unpaid.allSatisfy({ $0.payload.shares[store.userID.uuidString] == nil }) { Text("Add an equal split when editing a bill to track each adult's share.").foregroundStyle(.secondary) }
                }
                Section("Private banking") {
                    if !store.isLocal { NavigationLink("Your bank connections") { BankConnectionsView() } }
                    else { Text("Sign in to connect your bank. Shared bills work without a bank connection.").foregroundStyle(.secondary) }
                    Text("Bank accounts and transactions are visible only to the person who connected them.").font(.footnote).foregroundStyle(.secondary)
                }
                if !store.isLocal { Section { NavigationLink("Service quotes and payments") { ServiceQuotesView() } } }
            } else { ContentUnavailableView("Adult access required",systemImage:"lock",description:Text("Household bills and payments are available to adult members.")) }
        }.navigationTitle("Money").householdListStyle()
        .toolbar { if store.canManageMoney { Button("Add bill",systemImage:"plus") { editor = RecordEditorRequest(kind:.bill) } } }
        .sheet(item:$editor) { SharedRecordEditor(request:$0) }.refreshable { await store.sync() }
    }
}

struct BankConnectionsView: View {
    @SwiftUI.Environment(BackendClient.self) private var backend
    @State private var snapshot: BankSnapshot?
    @State private var busy = false
    @State private var error: String?
    @State private var query = ""
    @State private var disconnecting = false
    #if canImport(LinkKit)
    @State private var linkHandler: Handler?
    @State private var presentingLink = false
    #endif
    var body: some View {
        List {
            Section {
                Text("Only you can see these accounts and transactions.").font(.footnote).foregroundStyle(.secondary)
                if let snapshot {
                    Label(snapshot.environment == "sandbox" ? "Plaid Sandbox — test data" : "Connected banking",systemImage:snapshot.environment == "sandbox" ? "flask" : "building.columns")
                    if let refreshed = snapshot.refreshedAt { Text("Updated \(refreshed.formatted(.relative(presentation:.named)))").font(.footnote).foregroundStyle(.secondary) }
                }
                Button("Connect a bank") { connect() }.disabled(busy)
                #if DEBUG
                Button("Connect Plaid sandbox test bank") { run { let _: JSONValue = try await backend.function("bank/sandbox",[String:String]()); try await load() } }.disabled(busy)
                #endif
                if snapshot?.accounts.isEmpty == false {
                    Button("Refresh bank data") { run { let _: JSONValue = try await backend.function("bank/sync",[String:String]()); try await load() } }.disabled(busy)
                    Button("Disconnect all my banks",role:.destructive) { disconnecting = true }.disabled(busy)
                }
            }
            if let snapshot {
                Section("Accounts") {
                    ForEach(snapshot.accounts) { account in
                        VStack(alignment:.leading,spacing:5) {
                            LabeledContent(account.name,value:account.balanceCents.map { MoneyAmount.display($0,currency:account.currency) } ?? "Unavailable")
                            Text("\(account.institution) · \(account.mask.map { "••\($0)" } ?? account.type)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if snapshot.accounts.isEmpty { Text("No bank accounts connected.").foregroundStyle(.secondary) }
                }
                Section("Recent transactions") {
                    ForEach(snapshot.transactions.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { transaction in
                        VStack(alignment:.leading,spacing:4) {
                            LabeledContent(transaction.name,value:MoneyAmount.display(transaction.amountCents,currency:transaction.currency))
                            Text("\(transaction.date)\(transaction.pending ? " · Pending" : "")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if snapshot.transactions.isEmpty { Text("No transactions yet. New connections may take time to finish syncing.").foregroundStyle(.secondary) }
                }
            }
            if busy { ProgressView("Working…") }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Your banks").householdListStyle().searchable(text:$query,prompt:"Find a transaction")
        .task { run { try await load() } }.refreshable { run { try await load() } }
        .confirmationDialog("Disconnect all your banks?",isPresented:$disconnecting,titleVisibility:.visible) {
            Button("Disconnect",role:.destructive) { run { let _: JSONValue = try await backend.function("bank/disconnect",[String:String]()); snapshot = nil; try await load() } }
        } message: { Text("This removes your saved bank data and revokes the connections. Household bill records remain.") }
        #if canImport(LinkKit)
        .sheet(isPresented:$presentingLink) { PlaidLinkPresentation(handler:linkHandler) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { linkHandler?.resumeAfterTermination(from:url) }
        }
        #endif
    }
    private func load() async throws { snapshot = try await backend.function("bank/snapshot",[String:String]()) }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription } }
    }
    private func connect() {
        #if canImport(LinkKit)
        run {
            struct Token: Decodable { let link_token: String }
            let result: Token = try await backend.function("bank/link-token",[String:String]())
            var config = LinkTokenConfiguration(token:result.link_token) { success in
                Task { @MainActor in
                    presentingLink = false
                    run { let _: JSONValue = try await backend.function("bank/exchange",["public_token":success.publicToken]); try await load() }
                }
            }
            config.onExit = { exit in Task { @MainActor in presentingLink = false; if exit.error != nil { error = "Bank connection was interrupted. Please try again." } } }
            switch Plaid.create(config) {
            case .success(let handler): linkHandler = handler; presentingLink = true
            case .failure: throw BackendError.server("Bank connection could not open. Please try again.")
            }
        }
        #else
        error = "Bank linking is unavailable in this build."
        #endif
    }
}

#if canImport(LinkKit)
private struct PlaidLinkPresentation: UIViewControllerRepresentable {
    let handler: Handler?
    func makeUIViewController(context:Context) -> UIViewController { UIViewController() }
    func updateUIViewController(_ controller:UIViewController,context:Context) {
        guard !context.coordinator.opened, let handler else { return }
        context.coordinator.opened = true
        DispatchQueue.main.async { handler.open(presentUsing:.viewController(controller)) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var opened = false }
}
#endif

struct ServiceQuote: Codable, Identifiable {
    let id: UUID
    let providerName: String
    let amountCents: Int64
    let currency: String
    let description: String
    let status: String
    let expiresAt: Date
    enum CodingKeys: String,CodingKey { case id,providerName = "provider_name",amountCents = "amount_cents",currency,description,status,expiresAt = "expires_at" }
}
struct ServiceQuotesView: View {
    @SwiftUI.Environment(HouseholdStore.self) private var store
    @SwiftUI.Environment(\.openURL) private var openURL
    @State private var quotes: [ServiceQuote] = []
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        List {
            Section { Text("Review a provider's quote before paying. Payment status updates after Stripe confirms it.").foregroundStyle(.secondary) }
            ForEach(quotes) { quote in
                Section(quote.providerName) {
                    Text(quote.description)
                    LabeledContent("Amount",value:MoneyAmount.display(quote.amountCents,currency:quote.currency))
                    LabeledContent("Status",value:quote.status.capitalized)
                    if quote.status == "quoted" || quote.status == "checkout" {
                        Button("Review and pay with Stripe") {
                            busy = true
                            Task { defer { busy = false }; do {
                                struct Request:Encodable { let quote_id:UUID }
                                struct Result:Decodable { let url:URL }
                                let result:Result = try await store.backend.function("stripe/checkout",Request(quote_id:quote.id))
                                guard result.url.scheme == "https", result.url.host == "checkout.stripe.com" else { throw BackendError.server("Invalid payment link.") }
                                openURL(result.url)
                            } catch { self.error = error.localizedDescription } }
                        }.disabled(busy || quote.expiresAt < Date())
                    }
                }
            }
            if quotes.isEmpty { ContentUnavailableView("No service quotes",systemImage:"doc.text",description:Text("Quotes from onboarded providers will appear here when service booking is available.")) }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Service payments").task { await load() }.refreshable { await load() }
    }
    private func load() async {
        guard let household = store.household else { return }
        do { quotes = try await store.backend.get("rest/v1/service_quotes?household_id=eq.\(household.id)&select=*&order=created_at.desc"); error = nil } catch { self.error = error.localizedDescription }
    }
}
