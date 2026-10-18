import Foundation

// Records every outbound shopping session the user initiates.
// Conversion attribution events arrive server-side via Instacart webhooks (Phase 4+).
// This store only tracks what the client starts.

struct OutboundGrocerySession: Identifiable, Codable {
    let id: String
    let listName: String
    let listEmoji: String
    let itemCount: Int
    let provider: String
    let startedAt: Date
    let isSandbox: Bool
}

@Observable
@MainActor
final class GrocerySessionStore {
    private(set) var sessions: [OutboundGrocerySession] = []
    private let persistKey = "hh.grocerySessions"

    func load() {
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let decoded = try? JSONDecoder().decode([OutboundGrocerySession].self, from: data)
        else { return }
        sessions = decoded
    }

    func record(list: ShoppingList, provider: String) {
        let session = OutboundGrocerySession(
            id: UUID().uuidString,
            listName: list.name,
            listEmoji: list.emoji,
            itemCount: list.pendingCount,
            provider: provider,
            startedAt: Date(),
            isSandbox: FeatureFlags.sandboxBannerVisible
        )
        sessions.insert(session, at: 0)
        persist()
    }

    func lastSession(forListNamed name: String) -> OutboundGrocerySession? {
        sessions.first { $0.listName == name }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        UserDefaults.standard.set(data, forKey: persistKey)
    }
}
