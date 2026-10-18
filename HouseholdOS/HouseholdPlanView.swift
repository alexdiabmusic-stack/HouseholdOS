import SwiftUI
import StoreKit

struct HouseholdEntitlement: Decodable {
    let active: Bool
    let expiresAt: Date?
    let productID: String?
}
struct ServiceCapabilities: Decodable {
    let banking: Bool
    let grocery: Bool
    let servicePayments: Bool
    let subscriptions: Bool
}

struct HouseholdPlanView: View {
    @Environment(HouseholdStore.self) private var household
    @Environment(BackendClient.self) private var backend
    @Environment(\.openURL) private var openURL
    @State private var purchases = StoreKitStore()
    @State private var entitlement: HouseholdEntitlement?
    @State private var capabilities: ServiceCapabilities?
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        List {
            Section("Household OS+") {
                if entitlement?.active == true {
                    Label("Active for this household",systemImage:"checkmark.seal")
                    if let expiry = entitlement?.expiresAt { Text("Current period ends \(expiry.formatted(date:.abbreviated,time:.omitted))").foregroundStyle(.secondary) }
                } else { Text("Your household currently uses the core plan.") }
                if capabilities?.subscriptions != true { Text("Purchasing is not available in this build. Shared lists, tasks, and manual bills remain available.").font(.footnote).foregroundStyle(.secondary) }
            }
            if capabilities?.subscriptions == true && entitlement?.active != true && household.canManageMoney {
                Section("Available plans") {
                    ForEach(purchases.products,id:\.id) { product in
                        Button {
                            guard let id = household.household?.id else { return }
                            run { await purchases.purchase(product,appAccountToken:id); try await verifyPurchases() }
                        } label: { LabeledContent(product.displayName,value:product.displayPrice) }
                        .disabled(busy || purchases.isPurchasing)
                    }
                    if purchases.products.isEmpty { Text("Plans could not be loaded. Please try again later.").foregroundStyle(.secondary) }
                }
            }
            Section {
                Button("Restore purchases") { run { await purchases.restore(); try await verifyPurchases() } }.disabled(busy)
                Button("Manage subscriptions") { if let url = URL(string:"https://apps.apple.com/account/subscriptions") { openURL(url) } }
            }
            if let error { Text(error).foregroundStyle(.red) }
            if let purchaseError = purchases.purchaseError { Text(purchaseError).foregroundStyle(.red) }
            if busy { ProgressView() }
        }.navigationTitle("Household plan")
        .task {
            run {
                await purchases.load()
                capabilities = try await backend.function("capabilities",[String:String]())
                try await loadEntitlement()
            }
        }
    }
    private func loadEntitlement() async throws {
        guard let id = household.household?.id else { return }
        entitlement = try await backend.rpc("household_entitlement",["p_household_id":id])
    }
    private func verifyPurchases() async throws {
        guard let householdID = household.household?.id else { return }
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.appAccountToken == householdID {
                struct Request: Encodable { let household_id:UUID; let transaction_id:String }
                let _:HouseholdEntitlement = try await backend.function("storekit/verify",Request(household_id:householdID,transaction_id:String(transaction.id)))
            }
        }
        try await loadEntitlement()
        if entitlement?.active != true && purchases.isPremium { error = "The purchase is on your Apple ID but has not been verified for this household. Check the selected household or try Restore purchases again." }
    }
    private func run(_ action:@escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription } }
    }
}
