import Foundation

// Sandbox: returns mock Ottawa-area service providers.
// Production: calls a server-side endpoint that proxies Google Places API.
// Credentials (Google Places API key, Stripe Connect secret) never leave the server.
// Platform fee is computed and validated server-side; client never trusts its own calculation.
struct GooglePlacesSandboxProvider: MarketplaceProvider {

    private static let allProviders: [ServiceProvider] = [
        ServiceProvider(id: "prov-001", name: "Capital Cleaning Co.", category: "cleaning",
                        googleRating: 4.8, householdOSRating: 4.9,
                        address: "1234 Bank St, Ottawa, ON", phone: "+1 (613) 555-0101",
                        website: nil, isMarketplaceMember: true),
        ServiceProvider(id: "prov-002", name: "Sparkle Home Cleaning", category: "cleaning",
                        googleRating: 4.6, householdOSRating: 4.5,
                        address: "400 Laurier Ave W, Ottawa, ON", phone: "+1 (613) 555-0109",
                        website: nil, isMarketplaceMember: true),
        ServiceProvider(id: "prov-003", name: "Ottawa Pro Plumbing", category: "plumbing",
                        googleRating: 4.6, householdOSRating: 4.7,
                        address: "56 Rideau St, Ottawa, ON", phone: "+1 (613) 555-0102",
                        website: nil, isMarketplaceMember: true),
        ServiceProvider(id: "prov-004", name: "Drain Masters Plumbing", category: "plumbing",
                        googleRating: 4.5, householdOSRating: 4.4,
                        address: "12 Carling Ave, Ottawa, ON", phone: "+1 (613) 555-0110",
                        website: nil, isMarketplaceMember: false),
        ServiceProvider(id: "prov-005", name: "Bright Spark Electrical", category: "electrical",
                        googleRating: 4.9, householdOSRating: 4.9,
                        address: "789 Merivale Rd, Ottawa, ON", phone: "+1 (613) 555-0103",
                        website: nil, isMarketplaceMember: true),
        ServiceProvider(id: "prov-006", name: "Ottawa HVAC Solutions", category: "hvac",
                        googleRating: 4.7, householdOSRating: 4.6,
                        address: "22 Industrial Ave, Ottawa, ON", phone: "+1 (613) 555-0104",
                        website: nil, isMarketplaceMember: true),
        ServiceProvider(id: "prov-007", name: "Fix-It-All Handyman", category: "handyman",
                        googleRating: 4.5, householdOSRating: 4.5,
                        address: "88 Wellington St, Ottawa, ON", phone: "+1 (613) 555-0105",
                        website: nil, isMarketplaceMember: true),
        ServiceProvider(id: "prov-008", name: "Green Thumb Landscaping", category: "lawn",
                        googleRating: 4.8, householdOSRating: 4.8,
                        address: "300 Hunt Club Rd, Ottawa, ON", phone: "+1 (613) 555-0106",
                        website: nil, isMarketplaceMember: true),
        ServiceProvider(id: "prov-009", name: "Capital Movers", category: "moving",
                        googleRating: 4.4, householdOSRating: 4.3,
                        address: "1 Coventry Rd, Ottawa, ON", phone: "+1 (613) 555-0107",
                        website: nil, isMarketplaceMember: false),
        ServiceProvider(id: "prov-010", name: "PestAway Ottawa", category: "pest",
                        googleRating: 4.7, householdOSRating: 4.8,
                        address: "55 Sparks St, Ottawa, ON", phone: "+1 (613) 555-0108",
                        website: nil, isMarketplaceMember: true),
    ]

    func searchProviders(category: String, near location: GeoLocation) async throws -> [ServiceProvider] {
        try await Task.sleep(nanoseconds: 800_000_000)
        if category == "all" { return Self.allProviders }
        return Self.allProviders.filter { $0.category == category }
    }

    func createBooking(_ request: BookingRequest) async throws -> ServiceBooking {
        try await Task.sleep(nanoseconds: 1_100_000_000)
        return ServiceBooking(
            id: "booking-sandbox-\(UUID().uuidString.prefix(8).lowercased())",
            providerID: request.providerID,
            scheduledDate: request.scheduledDate,
            status: "confirmed",
            platformFeePercent: 8.0,
            totalAmount: request.estimatedCost
        )
    }
}
