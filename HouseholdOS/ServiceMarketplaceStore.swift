import Foundation

// MARK: - Booking Record

struct ServiceBookingRecord: Identifiable, Codable {
    let id: String
    let providerID: String
    let providerName: String
    let providerCategory: String
    let scheduledDate: Date
    let status: String           // "confirmed", "pending", "cancelled"
    let estimatedCost: Double?
    let platformFeePercent: Double
    let createdAt: Date
    let isSandbox: Bool
}

// MARK: - Service Marketplace Store

@Observable
@MainActor
final class ServiceMarketplaceStore {
    private(set) var searchResults: [ServiceProvider] = []
    private(set) var bookings: [ServiceBookingRecord] = []
    private(set) var isSearching = false
    private(set) var isBooking = false
    var lastError: String? = nil
    var selectedCategory = "all"

    private let provider: any MarketplaceProvider
    private let bookingsKey = "hh.serviceBookings"

    init(provider: any MarketplaceProvider) { self.provider = provider }
    convenience init() { self.init(provider: ProviderRegistry.marketplace) }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: bookingsKey),
              let decoded = try? JSONDecoder().decode([ServiceBookingRecord].self, from: data) else { return }
        bookings = decoded
    }

    func search(category: String) async {
        selectedCategory = category
        isSearching = true
        lastError = nil
        defer { isSearching = false }
        do {
            searchResults = try await provider.searchProviders(
                category: category,
                near: GeoLocation(latitude: 45.4215, longitude: -75.6972)  // Ottawa
            )
        } catch {
            lastError = error.localizedDescription
            searchResults = []
        }
    }

    func book(
        provider sp: ServiceProvider,
        date: Date,
        notes: String,
        estimatedCost: Double?
    ) async throws -> ServiceBookingRecord {
        isBooking = true
        defer { isBooking = false }

        let request = BookingRequest(
            providerID: sp.id,
            serviceCategory: sp.category,
            scheduledDate: date,
            notes: notes,
            estimatedCost: estimatedCost
        )
        let booking = try await provider.createBooking(request)

        let record = ServiceBookingRecord(
            id: booking.id,
            providerID: sp.id,
            providerName: sp.name,
            providerCategory: sp.category,
            scheduledDate: date,
            status: booking.status,
            estimatedCost: estimatedCost,
            platformFeePercent: booking.platformFeePercent,
            createdAt: Date(),
            isSandbox: FeatureFlags.sandboxBannerVisible
        )
        bookings.insert(record, at: 0)
        persist()
        return record
    }

    var upcomingBookings: [ServiceBookingRecord] {
        bookings
            .filter { $0.scheduledDate >= Date() && $0.status != "cancelled" }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(bookings) else { return }
        UserDefaults.standard.set(data, forKey: bookingsKey)
    }
}
