import Foundation

// MARK: - Rewards Store (Phase 7: Wildfire / Fidel)
//
// Reads reward offers and balance from the rewards provider.
// The rewards provider is a server-side proxy — the client never holds Wildfire
// or Fidel API credentials. Card-linked rewards are triggered by payment-network
// webhooks on the server; the app only reads the resulting balance/offer data.

@Observable
@MainActor
final class RewardsStore {
    private(set) var offers: [RewardOffer] = []
    private(set) var balance = RewardBalance(pending: 0, confirmed: 0, lifetime: 0)
    private(set) var isLoadingOffers = false
    private(set) var isLoadingBalance = false
    var loadError: String? = nil

    private let provider: any RewardsProvider

    init(provider: any RewardsProvider) { self.provider = provider }
    convenience init() { self.init(provider: ProviderRegistry.rewards) }

    func load() async {
        async let offersTask: () = loadOffers()
        async let balanceTask: () = loadBalance()
        _ = await (offersTask, balanceTask)
    }

    func loadOffers(near location: GeoLocation? = nil) async {
        isLoadingOffers = true
        defer { isLoadingOffers = false }
        do {
            offers = try await provider.offers(near: location)
        } catch {
            loadError = error.localizedDescription
        }
    }

    func loadBalance() async {
        isLoadingBalance = true
        defer { isLoadingBalance = false }
        do {
            balance = try await provider.balance()
        } catch {
            // Balance errors are non-fatal; show zero state
        }
    }

    var hasBalance: Bool { balance.confirmed > 0 || balance.pending > 0 }
    var totalBalance: Double { balance.confirmed + balance.pending }

    var topOffers: [RewardOffer] {
        offers.sorted { $0.rewardPercent > $1.rewardPercent }.prefix(5).map { $0 }
    }
}
