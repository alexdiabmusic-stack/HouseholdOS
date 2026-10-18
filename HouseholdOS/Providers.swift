import Foundation

// MARK: - Provider Architecture
// UI talks to domain services. Domain services talk to provider adapters.
// Never scatter vendor-specific API calls into UI components.
// Every provider must support a sandbox/mock implementation.

// MARK: - Financial Data Provider  (Phase 2: Plaid)

protocol FinancialDataProvider: Sendable {
    var name: String { get }
    var isConnected: Bool { get }
    func fetchAccounts() async throws -> [FinancialAccount]
    func fetchTransactions(from: Date, to: Date) async throws -> [FDTransaction]
    func fetchRecurringTransactions() async throws -> [FDRecurringTransaction]
}

// MARK: - Payment Provider  (Phase 4: VoPay)

protocol PaymentProvider: Sendable {
    var name: String { get }
    func schedulePayment(_ request: PaymentRequest) async throws -> PaymentResponse
    func cancelPayment(id: String) async throws
    func fetchStatus(paymentID: String) async throws -> PaymentStatus
}

// MARK: - Grocery Commerce Provider  (Phase 3: Instacart)

// Value type so items can cross actor boundaries safely (ListItem is a @Model class).
struct GroceryListItem: Sendable {
    let name: String
    let quantity: String
    let isChecked: Bool
}

protocol GroceryCommerceProvider: Sendable {
    var providerName: String { get }
    var ctaLabel: String { get }
    func createShoppingSession(items: [GroceryListItem]) async throws -> URL
}

// MARK: - Package Tracking Provider  (Phase 8: EasyPost)

protocol PackageTrackingProvider: Sendable {
    func track(number: String, carrier: String?) async throws -> PackageTrackingStatus
}

// MARK: - Weather Provider  (WeatherKit)

protocol WeatherProvider: Sendable {
    func currentConditions(lat: Double, lon: Double) async throws -> WeatherSnapshot
}

// MARK: - Holiday Provider  (Nager.Date)

protocol HolidayProvider: Sendable {
    func holidays(year: Int, countryCode: String) async throws -> [PublicHoliday]
}

// MARK: - Marketplace Provider  (Google Places + Stripe Connect)

protocol MarketplaceProvider: Sendable {
    func searchProviders(category: String, near location: GeoLocation) async throws -> [ServiceProvider]
    func createBooking(_ request: BookingRequest) async throws -> ServiceBooking
}

// MARK: - Rewards Provider  (Phase 7: Wildfire / Fidel)

protocol RewardsProvider: Sendable {
    func offers(near location: GeoLocation?) async throws -> [RewardOffer]
    func balance() async throws -> RewardBalance
}

// MARK: - Supporting Value Types

struct FDTransaction: Identifiable, Sendable {
    let id: String
    let date: Date
    let amount: Double
    let description: String
    let category: String
    let merchantName: String?
    let accountID: String
}

struct FDRecurringTransaction: Identifiable, Sendable {
    let id: String
    let amount: Double
    let frequency: String         // "monthly", "weekly", "annual"
    let merchantName: String
    let category: String
    let lastDate: Date
    let predictedNextDate: Date?
}

struct PaymentRequest: Sendable {
    let amount: Double
    let recipientID: String
    let memo: String
    let scheduleDate: Date
    let idempotencyKey: String
}

struct PaymentResponse: Sendable {
    let id: String
    let status: PaymentStatus
    let scheduledDate: Date
}

enum PaymentStatus: String, Sendable {
    case pending, processing, completed, failed, cancelled
}

struct PackageTrackingStatus: Identifiable, Sendable {
    let id: String
    let trackingNumber: String
    let carrier: String
    let status: String
    let estimatedDelivery: Date?
    let events: [TrackingEvent]
}

struct TrackingEvent: Identifiable, Sendable {
    let id: String
    let date: Date
    let description: String
    let location: String?
}

struct WeatherSnapshot: Sendable {
    let temperature: Double
    let feelsLike: Double
    let condition: String
    let snowfallCm: Double?
    let windSpeedKph: Double
}

struct PublicHoliday: Identifiable, Sendable {
    let id: String
    let date: Date
    let name: String
    let countryCode: String
}

struct GeoLocation: Sendable {
    let latitude: Double
    let longitude: Double
}

struct ServiceProvider: Identifiable, Sendable {
    let id: String
    let name: String
    let category: String
    let googleRating: Double?
    let householdOSRating: Double?
    let address: String?
    let phone: String?
    let website: URL?
    let isMarketplaceMember: Bool  // only true after full Stripe Connect onboarding
}

struct BookingRequest: Sendable {
    let providerID: String
    let serviceCategory: String
    let scheduledDate: Date
    let notes: String
    let estimatedCost: Double?
}

struct ServiceBooking: Identifiable, Sendable {
    let id: String
    let providerID: String
    let scheduledDate: Date
    let status: String
    let platformFeePercent: Double
    let totalAmount: Double?
}

struct RewardOffer: Identifiable, Sendable {
    let id: String
    let merchantName: String
    let rewardPercent: Double
    let description: String
    let expiryDate: Date?
    var category: String = "general"
}

struct RewardBalance: Sendable {
    let pending: Double
    let confirmed: Double
    let lifetime: Double
}

// MARK: - Mock / Sandbox Implementations

/// Returned when a feature flag is off or no credentials are configured.
/// Never returns real financial data or initiates real payments.
struct DisabledFinancialDataProvider: FinancialDataProvider {
    let name = "Not connected"
    let isConnected = false
    func fetchAccounts() async throws -> [FinancialAccount] { [] }
    func fetchTransactions(from: Date, to: Date) async throws -> [FDTransaction] { [] }
    func fetchRecurringTransactions() async throws -> [FDRecurringTransaction] { [] }
}

struct DisabledPaymentProvider: PaymentProvider {
    let name = "Not configured"
    func schedulePayment(_ request: PaymentRequest) async throws -> PaymentResponse {
        throw ProviderError.notEnabled
    }
    func cancelPayment(id: String) async throws { throw ProviderError.notEnabled }
    func fetchStatus(paymentID: String) async throws -> PaymentStatus { throw ProviderError.notEnabled }
}

struct DisabledGroceryCommerceProvider: GroceryCommerceProvider {
    let providerName = "Not configured"
    let ctaLabel = "Shop List"
    func createShoppingSession(items: [GroceryListItem]) async throws -> URL {
        throw ProviderError.notEnabled
    }
}

struct DisabledMarketplaceProvider: MarketplaceProvider {
    func searchProviders(category: String, near location: GeoLocation) async throws -> [ServiceProvider] {
        throw ProviderError.notEnabled
    }
    func createBooking(_ request: BookingRequest) async throws -> ServiceBooking {
        throw ProviderError.notEnabled
    }
}

struct DisabledRewardsProvider: RewardsProvider {
    func offers(near location: GeoLocation?) async throws -> [RewardOffer] { [] }
    func balance() async throws -> RewardBalance { RewardBalance(pending: 0, confirmed: 0, lifetime: 0) }
}

enum ProviderError: Error, LocalizedError {
    case notEnabled
    case notConnected
    case authRequired
    case sandboxOnly

    var errorDescription: String? {
        switch self {
        case .notEnabled:   return "This feature is not yet enabled."
        case .notConnected: return "Account not connected."
        case .authRequired: return "Authorization required."
        case .sandboxOnly:  return "This action is only available in sandbox mode."
        }
    }
}

// MARK: - Provider Registry  (inject real providers when feature flags are on)

// Computed vars rather than stored lets: avoids main-actor isolation inference warnings
// when used as default parameters in @MainActor store initialisers.
struct ProviderRegistry {
    // Phase 2: use sandbox provider while financialConnections flag is on but real Plaid is not yet wired.
    // Replace PlaidSandboxProvider() with a real PlaidProvider(token:) when backend is ready.
    static var financial: any FinancialDataProvider {
        FeatureFlags.financialConnections ? PlaidSandboxProvider() : DisabledFinancialDataProvider()
    }
    // Phase 4: use sandbox provider while vopayPayments flag is on but real VoPay is not wired.
    // Replace VoPaySandboxProvider() with a real VoPayProvider(serverURL:) when backend is ready.
    static var payment: any PaymentProvider {
        FeatureFlags.vopayPayments ? VoPaySandboxProvider() : DisabledPaymentProvider()
    }
    // Phase 3: use sandbox provider while instacartCommerce flag is on but real API is not wired.
    // Replace InstacartSandboxProvider() with a real InstacartProvider(serverURL:) when backend is ready.
    static var grocery: any GroceryCommerceProvider {
        FeatureFlags.instacartCommerce ? InstacartSandboxProvider() : DisabledGroceryCommerceProvider()
    }
    // Phase 5: use sandbox provider while serviceMarketplace flag is on but real Google Places is not wired.
    // Replace GooglePlacesSandboxProvider() with a real GooglePlacesProvider(serverURL:) when backend is ready.
    static var marketplace: any MarketplaceProvider {
        FeatureFlags.serviceMarketplace ? GooglePlacesSandboxProvider() : DisabledMarketplaceProvider()
    }
    // Phase 7: use sandbox provider while cashback/cardLinkedOffers flag is on but real Wildfire/Fidel is not wired.
    // Replace WildfireSandboxProvider() with a server-proxied RewardsProvider when backend is ready.
    // Affiliate and card-network credentials must never exist in the app bundle.
    static var rewards: any RewardsProvider {
        FeatureFlags.cashback ? WildfireSandboxProvider() : DisabledRewardsProvider()
    }
}
