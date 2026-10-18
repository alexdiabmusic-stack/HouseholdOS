import StoreKit
import Foundation

// MARK: - StoreKit 2 Subscription Store
//
// Phase 6: Household OS+ subscription via StoreKit 2.
// Products must be configured in HouseholdOSPlus.storekit (local testing) and
// App Store Connect (production). Receipt validation is server-side in production;
// client-side JWS verification is used only for display gating.
// DO NOT route digital subscription payments through any payment gateway other than
// StoreKit/App Store — this is required by App Store guidelines.

@Observable
@MainActor
final class StoreKitStore {
    static let monthlyProductID = "com.householdos.premium.monthly"
    static let annualProductID  = "com.householdos.premium.annual"

    private(set) var products: [Product] = []
    private(set) var purchasedProductIDs: Set<String> = []
    private(set) var isPurchasing = false
    private(set) var isRestoring = false
    var purchaseError: String? = nil

    var isPremium: Bool {
        purchasedProductIDs.contains(Self.monthlyProductID) ||
        purchasedProductIDs.contains(Self.annualProductID)
    }

    var activeProduct: Product? {
        products.first { purchasedProductIDs.contains($0.id) }
    }

    var monthlyProduct: Product? { products.first { $0.id == Self.monthlyProductID } }
    var annualProduct:  Product? { products.first { $0.id == Self.annualProductID } }

    nonisolated(unsafe) private var updatesTask: Task<Void, Never>?

    init() {}
    deinit { updatesTask?.cancel() }

    func load() async {
        await fetchProducts()
        await refreshEntitlements()
        startTransactionListener()
    }

    // MARK: - Product Fetching

    private func fetchProducts() async {
        do {
            let loaded = try await Product.products(for: [Self.monthlyProductID, Self.annualProductID])
            products = loaded.sorted { $0.price < $1.price }
        } catch {
            // Products not yet configured. Requires HouseholdOSPlus.storekit in scheme
            // (Edit Scheme → Run → Options → StoreKit Configuration) or App Store Connect setup.
        }
    }

    // MARK: - Purchase

    func purchase(_ product: Product, appAccountToken: UUID? = nil) async {
        purchaseError = nil
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let options: Set<Product.PurchaseOption> = appAccountToken.map { [.appAccountToken($0)] } ?? []
            let result = try await product.purchase(options: options)
            switch result {
            case .success(let verification):
                // Client-side JWS check only — grants local display access.
                // Production: server must independently validate the signed receipt
                // before unlocking server-side features.
                switch verification {
                case .verified(let transaction):
                    purchasedProductIDs.insert(transaction.productID)
                    await transaction.finish()
                case .unverified:
                    purchaseError = "Purchase could not be verified. Contact support if payment was charged."
                }
            case .userCancelled:
                break
            case .pending:
                purchaseError = "Purchase is awaiting approval."
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    // MARK: - Restore

    func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        do {
            // AppStore.sync() re-syncs the App Store receipt server-side.
            try await AppStore.sync()
        } catch {
            // sync failure is non-fatal; refreshEntitlements still runs
        }
        await refreshEntitlements()
    }

    // MARK: - Entitlement Refresh

    private func refreshEntitlements() async {
        var active: Set<String> = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let txn) = result, txn.revocationDate == nil, (txn.expirationDate.map { $0 > Date() } ?? true) {
                active.insert(txn.productID)
            }
        }
        purchasedProductIDs = active
    }

    // MARK: - Real-Time Updates

    private func startTransactionListener() {
        updatesTask?.cancel()
        updatesTask = Task {
            for await result in Transaction.updates {
                if case .verified(let txn) = result {
                    await txn.finish()
                    await refreshEntitlements()
                }
            }
        }
    }
}
