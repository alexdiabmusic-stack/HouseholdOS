import Foundation

// Sandbox implementation of GroceryCommerceProvider.
// In production this is replaced by a server-side proxy that:
//   1. Calls Instacart Partner API /v2/products/search for each item
//   2. Resolves product IDs, then POSTs to /v2/shoppable_lists
//   3. Returns the hosted shopping-experience URL to the client
// The Instacart partner key must never appear in the client bundle.

struct InstacartSandboxProvider: GroceryCommerceProvider {
    let providerName = "Instacart"
    let ctaLabel = "Shop on Instacart"

    func createShoppingSession(items: [GroceryListItem]) async throws -> URL {
        // Simulate partner API round-trip: product search + shoppable-list creation
        try await Task.sleep(nanoseconds: 850_000_000)

        let pending = items.filter { !$0.isChecked }
        guard !pending.isEmpty else { throw ProviderError.notConnected }

        // Build a sandbox-mode approximation of what the Instacart API returns.
        // Production: the URL is received from the API response — never constructed client-side.
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.instacart.com"
        components.path = "/store/household_os/shoppable_list"
        components.queryItems = [
            URLQueryItem(name: "partner",    value: "household_os"),
            URLQueryItem(name: "utm_source", value: "household_os"),
            URLQueryItem(name: "utm_medium", value: "app"),
            URLQueryItem(name: "sandbox",    value: "true"),
        ] + pending.map { URLQueryItem(name: "item[]", value: normalized($0)) }

        guard let url = components.url else { throw ProviderError.sandboxOnly }
        return url
    }

    // Produce a search-friendly string Instacart's product resolver can match.
    private func normalized(_ item: GroceryListItem) -> String {
        let name = item.name.trimmingCharacters(in: .whitespaces).lowercased()
        let qty  = item.quantity.trimmingCharacters(in: .whitespaces)
        return qty.isEmpty ? name : "\(qty) \(name)"
    }
}
