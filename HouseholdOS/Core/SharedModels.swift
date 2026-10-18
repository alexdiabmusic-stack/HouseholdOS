import Foundation

enum RecordKind: String, Codable, CaseIterable, Identifiable {
    case list, item, task, bill, asset
    var id: String { rawValue }
}

enum RepeatRule: String, Codable, CaseIterable, Identifiable {
    case none, daily, weekly, monthly, yearly
    var id: String { rawValue }
    var label: String { self == .none ? "Does not repeat" : rawValue.capitalized }
}

struct SharedSubtask: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var completed = false
}

struct SharedFields: Codable, Equatable, Sendable {
    var title: String
    var notes = ""
    var parentID: UUID?
    var quantity = ""
    var aisle = ""
    var completed = false
    var assigneeID: UUID?
    var dueAt: Date?
    var repeatRule: RepeatRule = .none
    var anchorDay: Int?
    var completedAt: Date?
    var amountCents: Int64 = 0
    var currency = "CAD"
    var paid = false
    var paidByID: UUID?
    var paidAt: Date?
    var previousID: UUID?
    var shares: [String: Int64] = [:]
    var attachmentURL: String?
    var shoppingByID: UUID?
    var subtasks: [SharedSubtask] = []
    var rotation: [UUID] = []

    init(title:String) { self.title = title }
    enum CodingKeys:String,CodingKey {
        case title,notes,parentID,quantity,aisle,completed,assigneeID,dueAt,repeatRule,anchorDay,completedAt,amountCents,currency,paid,paidByID,paidAt,previousID,shares,attachmentURL,shoppingByID,subtasks,rotation
    }
    init(from decoder:Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        title = try c.decode(String.self,forKey:.title)
        notes = try c.decodeIfPresent(String.self,forKey:.notes) ?? ""
        parentID = try c.decodeIfPresent(UUID.self,forKey:.parentID)
        quantity = try c.decodeIfPresent(String.self,forKey:.quantity) ?? ""
        aisle = try c.decodeIfPresent(String.self,forKey:.aisle) ?? ""
        completed = try c.decodeIfPresent(Bool.self,forKey:.completed) ?? false
        assigneeID = try c.decodeIfPresent(UUID.self,forKey:.assigneeID)
        dueAt = try c.decodeIfPresent(Date.self,forKey:.dueAt)
        repeatRule = try c.decodeIfPresent(RepeatRule.self,forKey:.repeatRule) ?? .none
        anchorDay = try c.decodeIfPresent(Int.self,forKey:.anchorDay)
        completedAt = try c.decodeIfPresent(Date.self,forKey:.completedAt)
        amountCents = try c.decodeIfPresent(Int64.self,forKey:.amountCents) ?? 0
        currency = try c.decodeIfPresent(String.self,forKey:.currency) ?? "CAD"
        paid = try c.decodeIfPresent(Bool.self,forKey:.paid) ?? false
        paidByID = try c.decodeIfPresent(UUID.self,forKey:.paidByID)
        paidAt = try c.decodeIfPresent(Date.self,forKey:.paidAt)
        previousID = try c.decodeIfPresent(UUID.self,forKey:.previousID)
        shares = try c.decodeIfPresent([String:Int64].self,forKey:.shares) ?? [:]
        attachmentURL = try c.decodeIfPresent(String.self,forKey:.attachmentURL)
        shoppingByID = try c.decodeIfPresent(UUID.self,forKey:.shoppingByID)
        subtasks = try c.decodeIfPresent([SharedSubtask].self,forKey:.subtasks) ?? []
        rotation = try c.decodeIfPresent([UUID].self,forKey:.rotation) ?? []
    }
}

struct SharedRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var householdID: UUID
    var kind: RecordKind
    var payload: SharedFields
    var version: Int64
    var deleted: Bool
    var updatedBy: UUID?
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, kind, payload, version, deleted
        case householdID = "household_id", updatedBy = "updated_by", updatedAt = "updated_at"
    }
    var isFinished: Bool { kind == .bill ? payload.paid : payload.completed }
    var isOverdue: Bool {
        guard !isFinished, let due = payload.dueAt else { return false }
        return due < Date()
    }
}

struct SharedHousehold: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var timezone: String
    var currency: String
}

struct SharedMember: Codable, Identifiable, Equatable, Sendable {
    let householdID: UUID
    let userID: UUID
    var displayName: String
    var role: String
    var id: UUID { userID }
    enum CodingKeys: String, CodingKey {
        case householdID = "household_id", userID = "user_id", displayName = "display_name", role
    }
}

struct SharedInvite: Codable, Identifiable, Sendable {
    let id: UUID
    let token: String
    let invitedEmail: String
    let expiresAt: Date
    let acceptedBy: UUID?
    let revokedAt: Date?
    enum CodingKeys: String, CodingKey {
        case id, token, invitedEmail = "invited_email", expiresAt = "expires_at"
        case acceptedBy = "accepted_by", revokedAt = "revoked_at"
    }
    var url: URL { URL(string: "householdos://invite?token=\(token)")! }
}

struct SharedActivity: Codable, Identifiable, Sendable {
    let id: Int64
    let recordID: UUID?
    let actorName: String
    let action: String
    let title: String
    let createdAt: Date
    enum CodingKeys: String, CodingKey {
        case id, recordID = "record_id", actorName = "actor_name", action, title, createdAt = "created_at"
    }
}

struct PendingMutation: Codable, Identifiable, Sendable {
    var id = UUID()
    var record: SharedRecord
    var baseVersion: Int64
}

struct RecordConflict: Identifiable {
    var id: UUID { draft.id }
    let draft: SharedRecord
    let remote: SharedRecord?
}

struct MutationResult: Codable {
    let conflict: Bool
    let record: SharedRecord?
    let nextRecord: SharedRecord?
}

enum SharedCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let raw = try value.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: try value.singleValueContainer(), debugDescription: "Invalid server date")
        }
        return decoder
    }
}

enum MoneyAmount {
    static func cents(_ text: String, locale: Locale = .current) -> Int64? {
        let trimmed = text.trimmingCharacters(in:.whitespacesAndNewlines)
        let separator = locale.decimalSeparator ?? "."
        let escaped = NSRegularExpression.escapedPattern(for:separator)
        guard trimmed.range(of:"^[0-9]+(?:\(escaped)[0-9]{1,2})?$",options:.regularExpression) != nil else { return nil }
        let number = NSDecimalNumber(string:trimmed.replacingOccurrences(of:separator,with:"."),locale:Locale(identifier:"en_US_POSIX"))
        guard number != .notANumber else { return nil }
        let scaled = number.multiplying(by: 100)
        let rounded = scaled.rounding(accordingToBehavior: NSDecimalNumberHandler(roundingMode: .plain, scale: 0, raiseOnExactness: false, raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false))
        guard rounded == scaled, rounded.compare(0) == .orderedDescending, rounded.compare(100_000_000) != .orderedDescending else { return nil }
        return rounded.int64Value
    }
    static func display(_ cents: Int64, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: NSDecimalNumber(value: cents).dividing(by: 100)) ?? "—"
    }
}
