import SwiftData
import SwiftUI
import Foundation

// MARK: - Brand Colors

extension Color {
    static let hhBg     = Color(red: 0.961, green: 0.945, blue: 0.925) // #f5f1ec
    static let hhCard   = Color(red: 1.0,   green: 1.0,   blue: 1.0)   // #ffffff
    static let hhAccent = Color(red: 0.761, green: 0.427, blue: 0.310) // #c26d4f
    static let hhInk    = Color(red: 0.169, green: 0.149, blue: 0.125) // #2b2620
    static let hhSub    = Color(red: 0.561, green: 0.522, blue: 0.478) // #8f857a
    static let hhFaint  = Color(red: 0.702, green: 0.655, blue: 0.604) // #b3a79a
    static let hhShell  = Color(red: 0.914, green: 0.902, blue: 0.878) // #e9e6e0
    static let hhGreen  = Color(red: 0.31,  green: 0.686, blue: 0.533) // #4faf88
    static let hhBlue   = Color(red: 0.29,  green: 0.565, blue: 0.886) // #4a90e2
    static let hhPurple = Color(red: 0.639, green: 0.427, blue: 0.773)
}

// MARK: - HouseholdTask

@Model
final class HouseholdTask {
    var name: String
    var emoji: String
    var category: String
    var sortOrder: Int
    var createdAt: Date
    @Relationship(deleteRule: .cascade) var completions: [DailyCompletion] = []

    init(name: String, emoji: String, category: String = "chore", sortOrder: Int = 0) {
        self.name = name
        self.emoji = emoji
        self.category = category
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }

    var isCompletedToday: Bool {
        let today = Calendar.current.startOfDay(for: Date())
        return completions.contains { Calendar.current.startOfDay(for: $0.date) == today }
    }

    var currentStreak: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let uniqueDays = Set(completions.map { cal.startOfDay(for: $0.date) })
        let startDate: Date
        if uniqueDays.contains(today) {
            startDate = today
        } else {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: today),
                  uniqueDays.contains(yesterday) else { return 0 }
            startDate = yesterday
        }
        var streak = 0
        var check = startDate
        while uniqueDays.contains(check) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: check) else { break }
            check = prev
        }
        return streak
    }

    var bestStreak: Int {
        let cal = Calendar.current
        let deduped = Array(Set(completions.map { cal.startOfDay(for: $0.date) })).sorted()
        guard !deduped.isEmpty else { return 0 }
        var best = 1, current = 1
        for i in 1..<deduped.count {
            if let diff = cal.dateComponents([.day], from: deduped[i - 1], to: deduped[i]).day, diff == 1 {
                current += 1
                best = max(best, current)
            } else {
                current = 1
            }
        }
        return max(best, current)
    }

    var totalCompletionDays: Int {
        Set(completions.map { Calendar.current.startOfDay(for: $0.date) }).count
    }
}

// MARK: - DailyCompletion

@Model
final class DailyCompletion {
    var date: Date
    var task: HouseholdTask?

    init(date: Date = Date()) {
        self.date = date
    }
}

// MARK: - TaskCategory

enum TaskCategory: String, CaseIterable, Identifiable {
    case chore    = "chore"
    case bill     = "bill"
    case supply   = "supply"
    case maintain = "maintain"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chore:    return "Chores"
        case .bill:     return "Bills"
        case .supply:   return "Supplies"
        case .maintain: return "Maintenance"
        }
    }

    var icon: String {
        switch self {
        case .chore:    return "sparkles"
        case .bill:     return "dollarsign.circle"
        case .supply:   return "cart"
        case .maintain: return "wrench.and.screwdriver"
        }
    }

    var color: Color {
        switch self {
        case .chore:    return .hhAccent
        case .bill:     return .hhBlue
        case .supply:   return .hhGreen
        case .maintain: return .hhPurple
        }
    }
}

// MARK: - ShoppingList

@Model
final class ShoppingList {
    var name: String
    var emoji: String
    var listType: String   // "grocery", "errands", "costco", "custom"
    var sortOrder: Int
    var createdAt: Date
    var claimedBy: String?
    @Relationship(deleteRule: .cascade) var items: [ListItem] = []

    init(name: String, emoji: String, listType: String = "grocery", sortOrder: Int = 0) {
        self.name = name
        self.emoji = emoji
        self.listType = listType
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }

    var pendingCount: Int { items.filter { !$0.isChecked }.count }
    var checkedCount: Int { items.filter { $0.isChecked }.count }
}

// MARK: - ListItem

@Model
final class ListItem {
    var name: String
    var quantity: String
    var isChecked: Bool
    var isSuggested: Bool
    var sortOrder: Int
    var addedAt: Date

    init(name: String, quantity: String = "", isChecked: Bool = false,
         isSuggested: Bool = false, sortOrder: Int = 0) {
        self.name = name
        self.quantity = quantity
        self.isChecked = isChecked
        self.isSuggested = isSuggested
        self.sortOrder = sortOrder
        self.addedAt = Date()
    }
}

// MARK: - MaintenanceTask

@Model
final class MaintenanceTask {
    var name: String
    var emoji: String
    var category: String   // "hvac", "plumbing", "seasonal", "appliance", "general"
    var notes: String
    var dueDate: Date?
    var completedDate: Date?
    var intervalDays: Int?  // for recurring tasks
    var isDIY: Bool
    var priority: String    // "low", "medium", "high", "urgent"
    var createdAt: Date

    init(name: String, emoji: String, category: String = "general", notes: String = "",
         dueDate: Date? = nil, isDIY: Bool = true, priority: String = "medium",
         intervalDays: Int? = nil) {
        self.name = name
        self.emoji = emoji
        self.category = category
        self.notes = notes
        self.dueDate = dueDate
        self.isDIY = isDIY
        self.priority = priority
        self.intervalDays = intervalDays
        self.createdAt = Date()
    }

    var isOverdue: Bool {
        guard let due = dueDate, completedDate == nil else { return false }
        return due < Calendar.current.startOfDay(for: Date())
    }

    var isDueSoon: Bool {
        guard let due = dueDate, completedDate == nil else { return false }
        let soon = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        return due <= soon && !isOverdue
    }

    var isComplete: Bool { completedDate != nil }
}

// MARK: - Bill  (Phase 1: value type, not persisted — replaced by Plaid data in Phase 2)

struct Bill: Identifiable {
    let id: UUID
    var name: String
    var emoji: String
    var amount: Double
    var dueDate: Date
    var isPaid: Bool
    var category: String
    var typicalMin: Double?
    var typicalMax: Double?
    var isAutoScheduled: Bool

    init(id: UUID = UUID(), name: String, emoji: String, amount: Double, dueDate: Date,
         isPaid: Bool = false, category: String = "utility",
         typicalMin: Double? = nil, typicalMax: Double? = nil, isAutoScheduled: Bool = false) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.amount = amount
        self.dueDate = dueDate
        self.isPaid = isPaid
        self.category = category
        self.typicalMin = typicalMin
        self.typicalMax = typicalMax
        self.isAutoScheduled = isAutoScheduled
    }

    var isOverdue: Bool { !isPaid && dueDate < Calendar.current.startOfDay(for: Date()) }

    var isDueSoon: Bool {
        guard !isPaid && !isOverdue else { return false }
        let soon = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        return dueDate <= soon
    }

    var isUnusual: Bool {
        guard let max = typicalMax else { return false }
        return amount > max * 1.2
    }

    var daysUntilDue: Int {
        Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: dueDate).day ?? 0
    }
}

// MARK: - FinancialAccount  (Phase 1: mock, replaced by Plaid data in Phase 2)

struct FinancialAccount: Identifiable {
    let id: UUID
    var institutionName: String
    var accountName: String
    var accountType: String  // "checking", "savings", "credit"
    var balance: Double
    var availableBalance: Double?
    var lastUpdated: Date
    var maskNumber: String?

    init(id: UUID = UUID(), institutionName: String, accountName: String,
         accountType: String, balance: Double, availableBalance: Double? = nil,
         lastUpdated: Date = Date(), maskNumber: String? = nil) {
        self.id = id
        self.institutionName = institutionName
        self.accountName = accountName
        self.accountType = accountType
        self.balance = balance
        self.availableBalance = availableBalance
        self.lastUpdated = lastUpdated
        self.maskNumber = maskNumber
    }
}

// MARK: - HouseholdMember

struct HouseholdMember: Identifiable {
    let id: UUID
    var name: String
    var initials: String
    var role: String   // "owner", "member", "child"
    var email: String?
    var isCurrentUser: Bool

    init(id: UUID = UUID(), name: String, role: String = "owner",
         email: String? = nil, isCurrentUser: Bool = false) {
        self.id = id
        self.name = name
        self.initials = name.components(separatedBy: " ")
            .compactMap { $0.first.map(String.init) }.joined()
        self.role = role
        self.email = email
        self.isCurrentUser = isCurrentUser
    }
}

// MARK: - Today Card

enum TodayCardPriority: Int, Comparable {
    case urgent = 0, high = 1, medium = 2, low = 3
    static func < (lhs: TodayCardPriority, rhs: TodayCardPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct TodayCard: Identifiable {
    let id: String
    let kind: TodayCardKind
    let priority: TodayCardPriority
}

enum TodayCardKind {
    // Phase 2: detected bills from FinancialStore (replaces Phase 1 Bill struct cards)
    case billDue(DetectedBill)
    case billOverdue(DetectedBill)
    case billUnusual(DetectedBill)
    case groceryListPending(ShoppingList)
    case maintenanceDue(MaintenanceTask)
    case maintenanceOverdue(MaintenanceTask)
    case routinesPending(completed: Int, total: Int)
    // Phase 8: spending anomaly from InsightsEngine
    case spendingAnomaly(SpendingAnomaly)
}
