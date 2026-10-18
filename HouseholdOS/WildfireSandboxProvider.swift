import Foundation

// Sandbox: returns mock cashback offers and a simulated balance.
// Production: calls a server-side endpoint that proxies the Wildfire or Fidel API.
// Affiliate/card-network credentials never belong in the app bundle.
// Card-linked rewards are triggered by payment network webhooks server-side;
// the client never initiates a reward — it only reads balance/offer data.
struct WildfireSandboxProvider: RewardsProvider {

    private static let mockBalance = RewardBalance(
        pending: 3.21, confirmed: 12.47, lifetime: 45.83
    )

    private static let mockOffers: [RewardOffer] = [
        RewardOffer(id: "offer-001", merchantName: "Tim Hortons",       rewardPercent: 3.0,
                    description: "Earn 3% back on all purchases",
                    expiryDate: cal.date(byAdding: .month, value: 2, to: now), category: "food"),
        RewardOffer(id: "offer-002", merchantName: "Shoppers Drug Mart", rewardPercent: 2.5,
                    description: "Earn 2.5% back on health & beauty",
                    expiryDate: cal.date(byAdding: .month, value: 3, to: now), category: "health"),
        RewardOffer(id: "offer-003", merchantName: "Canadian Tire",      rewardPercent: 3.5,
                    description: "Earn 3.5% back on automotive & home",
                    expiryDate: nil, category: "home"),
        RewardOffer(id: "offer-004", merchantName: "Sport Chek",         rewardPercent: 4.0,
                    description: "Earn 4% back on sports & fitness",
                    expiryDate: cal.date(byAdding: .month, value: 1, to: now), category: "sports"),
        RewardOffer(id: "offer-005", merchantName: "Harvey's",           rewardPercent: 5.0,
                    description: "Earn 5% back on food orders",
                    expiryDate: cal.date(byAdding: .day, value: 14, to: now), category: "food"),
        RewardOffer(id: "offer-006", merchantName: "Best Buy",           rewardPercent: 2.5,
                    description: "Earn 2.5% back on electronics",
                    expiryDate: nil, category: "tech"),
        RewardOffer(id: "offer-007", merchantName: "PetSmart",           rewardPercent: 5.0,
                    description: "Earn 5% back on pet supplies",
                    expiryDate: cal.date(byAdding: .month, value: 2, to: now), category: "pets"),
        RewardOffer(id: "offer-008", merchantName: "IKEA",               rewardPercent: 3.0,
                    description: "Earn 3% back on home & furniture",
                    expiryDate: nil, category: "home"),
        RewardOffer(id: "offer-009", merchantName: "Loblaws",            rewardPercent: 2.0,
                    description: "Earn 2% back on groceries",
                    expiryDate: nil, category: "grocery"),
        RewardOffer(id: "offer-010", merchantName: "Esso",               rewardPercent: 2.0,
                    description: "Earn 2% back on fuel & convenience",
                    expiryDate: cal.date(byAdding: .month, value: 1, to: now), category: "auto"),
        RewardOffer(id: "offer-011", merchantName: "Winners",            rewardPercent: 4.0,
                    description: "Earn 4% back on fashion & home",
                    expiryDate: cal.date(byAdding: .month, value: 2, to: now), category: "fashion"),
        RewardOffer(id: "offer-012", merchantName: "Mark's",             rewardPercent: 4.0,
                    description: "Earn 4% back on clothing & workwear",
                    expiryDate: nil, category: "fashion"),
        RewardOffer(id: "offer-013", merchantName: "Staples",            rewardPercent: 3.0,
                    description: "Earn 3% back on office supplies",
                    expiryDate: cal.date(byAdding: .month, value: 2, to: now), category: "tech"),
        RewardOffer(id: "offer-014", merchantName: "HomeSense",          rewardPercent: 4.0,
                    description: "Earn 4% back on home décor",
                    expiryDate: nil, category: "home"),
    ]

    private static let now = Date()
    private static let cal = Calendar.current

    func offers(near location: GeoLocation?) async throws -> [RewardOffer] {
        try await Task.sleep(nanoseconds: 700_000_000)
        return Self.mockOffers
    }

    func balance() async throws -> RewardBalance {
        try await Task.sleep(nanoseconds: 400_000_000)
        return Self.mockBalance
    }
}
