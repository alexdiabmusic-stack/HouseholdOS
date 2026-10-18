import Foundation
import Observation
import Security

struct AppConfiguration: Sendable {
    let url: URL?
    let publicKey: String
    static let current: AppConfiguration = {
        var values: [String: Any] = [:]
        if let file = Bundle.main.url(forResource: "ServiceConfiguration", withExtension: "plist"),
           let data = try? Data(contentsOf: file),
           let loaded = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] { values = loaded }
        let endpoint = values["SUPABASE_URL"] as? String ?? Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
        let key = values["SUPABASE_PUBLISHABLE_KEY"] as? String ?? Bundle.main.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String ?? ""
        let candidate = URL(string: endpoint)
        return AppConfiguration(url: candidate?.scheme == "https" && candidate?.host != nil ? candidate : nil, publicKey: key)
    }()
    var isConfigured: Bool { url != nil && !publicKey.isEmpty && !publicKey.contains("$(") }
}

struct AuthUser: Codable, Sendable {
    let id: UUID
    let email: String?
    let emailConfirmedAt: Date?
    enum CodingKeys: String, CodingKey { case id, email, emailConfirmedAt = "email_confirmed_at" }
}

struct AuthSession: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresIn: Int
    var user: AuthUser
    var savedAt: Date = Date()
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in", user
    }
    var needsRefresh: Bool { Date().timeIntervalSince(savedAt) >= Double(expiresIn - 90) }
}

enum BackendError: LocalizedError {
    case configuration, signedOut, server(String), response(Int,String), sessionStorage
    var errorDescription: String? {
        switch self {
        case .configuration: return "Shared households are not configured in this build. You can use an on-device household."
        case .signedOut: return "Sign in again to reconnect your household."
        case .server(let message): return message
        case .response(_,let message): return message
        case .sessionStorage: return "The secure session could not be saved. Please try signing in again."
        }
    }
}

enum SessionKeychain {
    private static let service = "HouseholdOS.Auth"
    static func read() -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    static func write(_ data: Data) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session"]
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecItemNotFound {
            var entry = query
            entry[kSecValueData as String] = data
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw BackendError.sessionStorage }
        } else if updated != errSecSuccess { throw BackendError.sessionStorage }
    }
    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session"] as CFDictionary)
    }
}

@Observable @MainActor final class BackendClient {
    let configuration: AppConfiguration
    private(set) var session: AuthSession?
    private(set) var isRestoring = true
    var error: String?
    var confirmationEmail: String?
    private var refreshTask: Task<AuthSession, Error>?

    init(configuration: AppConfiguration = .current) { self.configuration = configuration }

    func restore() async {
        defer { isRestoring = false }
        guard configuration.isConfigured, let data = SessionKeychain.read(),
              let restored = try? SharedCoding.decoder().decode(AuthSession.self, from: data) else { return }
        session = restored
        session?.savedAt = .distantPast
        // Always rotate on launch: savedAt deliberately is not persisted.
        do { _ = try await refresh() } catch { self.error = error.localizedDescription }
    }

    func signUp(email: String, password: String) async throws {
        guard password.count >= 12 else { throw BackendError.server("Use a password with at least 12 characters.") }
        let _: [String: JSONValue] = try await request("auth/v1/signup", body: ["email":email,"password":password], authenticated: false)
        confirmationEmail = email
    }

    func signIn(email: String, password: String) async throws {
        let result: AuthSession = try await request("auth/v1/token?grant_type=password", body: ["email":email,"password":password], authenticated: false)
        try install(result)
    }

    func verify(email: String, code: String) async throws {
        let result: AuthSession = try await request("auth/v1/verify", body: ["email":email,"token":code,"type":"signup"], authenticated: false)
        try install(result)
        confirmationEmail = nil
    }

    func resend(email: String) async throws {
        let _: JSONValue = try await request("auth/v1/resend", body: ["email":email,"type":"signup"], authenticated: false)
    }

    func requestPasswordReset(email: String) async throws {
        let _: JSONValue = try await request("auth/v1/recover", body: ["email":email], authenticated: false)
    }

    func resetPassword(email: String, code: String, password: String) async throws {
        guard password.count >= 12 else { throw BackendError.server("Use at least 12 characters.") }
        let recovery: AuthSession = try await request("auth/v1/verify", body: ["email":email,"token":code,"type":"recovery"], authenticated: false)
        try install(recovery)
        let _: AuthUser = try await request("auth/v1/user", method:"PUT", body:["password":password])
    }

    func signOut() async {
        if session != nil { let _: JSONValue? = try? await request("auth/v1/logout", body: [String:String]()) }
        session = nil
        SessionKeychain.clear()
    }

    func accessToken() async throws -> String {
        guard let current = session else { throw BackendError.signedOut }
        if current.needsRefresh { return try await refresh().accessToken }
        return current.accessToken
    }

    private func refresh() async throws -> AuthSession {
        if let task = refreshTask { return try await task.value }
        guard let current = session else { throw BackendError.signedOut }
        let task = Task<AuthSession, Error> {
            try await self.request("auth/v1/token?grant_type=refresh_token", body: ["refresh_token":current.refreshToken], authenticated: false)
        }
        refreshTask = task
        defer { refreshTask = nil }
        let result = try await task.value
        try install(result)
        return result
    }

    private func install(_ newSession: AuthSession) throws {
        guard newSession.user.emailConfirmedAt != nil else { throw BackendError.server("Verify your email address before signing in.") }
        try SessionKeychain.write(SharedCoding.encoder().encode(newSession))
        session = newSession
        error = nil
    }

    func request<Response: Decodable, Body: Encodable>(_ path: String, method: String = "POST", body: Body, authenticated: Bool = true) async throws -> Response {
        try await perform(path, method: method, data: SharedCoding.encoder().encode(body), authenticated: authenticated)
    }
    func get<Response: Decodable>(_ path: String) async throws -> Response {
        try await perform(path, method: "GET", data: nil, authenticated: true)
    }
    func rpc<Response: Decodable, Body: Encodable>(_ name: String, _ body: Body) async throws -> Response {
        try await request("rest/v1/rpc/\(name)", body: body)
    }
    func function<Response: Decodable, Body: Encodable>(_ action: String, _ body: Body) async throws -> Response {
        try await request("functions/v1/household-api/\(action)", body: body)
    }

    private func perform<Response: Decodable>(_ path: String, method: String, data: Data?, authenticated: Bool) async throws -> Response {
        guard configuration.isConfigured, let base = configuration.url,
              let url = URL(string: "\(base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(path)") else { throw BackendError.configuration }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = data
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.publicKey, forHTTPHeaderField: "apikey")
        if authenticated { request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackendError.server("No response. Try again.") }
        guard (200..<300).contains(http.statusCode) else {
            let problem = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
            let message = problem?["message"] as? String ?? problem?["msg"] as? String ?? problem?["error_description"] as? String ?? problem?["error"] as? String ?? "The service is unavailable. Try again."
            throw BackendError.response(http.statusCode,message)
        }
        return try SharedCoding.decoder().decode(Response.self, from: bytes.isEmpty ? Data("null".utf8) : bytes)
    }
}

// Handles heterogeneous Auth responses without storing or logging token dictionaries.
enum JSONValue: Codable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String:JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        }
    }
}
