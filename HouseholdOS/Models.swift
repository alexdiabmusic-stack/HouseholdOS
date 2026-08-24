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

// MARK: - Category

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
        case .chore:    return Color(red: 0.761, green: 0.427, blue: 0.310)
        case .bill:     return Color(red: 0.29, green: 0.565, blue: 0.886)
        case .supply:   return Color(red: 0.31, green: 0.686, blue: 0.533)
        case .maintain: return Color(red: 0.639, green: 0.427, blue: 0.773)
        }
    }
}
