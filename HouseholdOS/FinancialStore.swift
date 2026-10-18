import Foundation
import SwiftUI

// MARK: - Financial Domain Models (Phase 2)

struct DetectedBill: Identifiable {
    let id: String
    let merchantName: String
    let emoji: String
    let amount: Double
    let frequency: String
    let lastTransactionDate: Date
    let predictedNextDate: Date?
    let category: String
    var isConfirmed: Bool
    var isPaidThisMonth: Bool

    var daysUntilDue: Int? {
        guard let next = predictedNextDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: next).day
    }

    var isDueSoon: Bool {
        guard let days = daysUntilDue else { return false }
        return days >= 0 && days <= 7
    }

    var isOverdue: Bool {
        guard let days = daysUntilDue, !isPaidThisMonth else { return false }
        return days < 0
    }
}

struct DetectedSubscription: Identifiable {
    let id: String
    let merchantName: String
    let emoji: String
    let amount: Double
    let frequency: String
    let lastCharge: Date
    let previousAmount: Double?
    let annualCost: Double
    var isTracked: Bool = true

    var hasIncreased: Bool { (previousAmount ?? 0) < amount && previousAmount != nil }
    var increaseAmount: Double? {
        guard let prev = previousAmount, amount > prev else { return nil }
        return amount - prev
    }
}

// MARK: - Transaction Display Category

struct TxCategory {
    let label: String
    let icon: String
    let color: Color

    static func from(plaidCategory: String, merchantName: String) -> TxCategory {
        let lower = plaidCategory.lowercased()
        if lower == "income"                              { return .init(label: "Income",       icon: "arrow.down.circle",         color: .hhGreen) }
        if lower == "groceries"                           { return .init(label: "Groceries",    icon: "cart",                      color: .hhGreen) }
        if lower == "food_and_drink"                      { return .init(label: "Dining",       icon: "fork.knife",                color: .orange) }
        if lower == "rent" || lower == "mortgage"         { return .init(label: "Housing",      icon: "house",                     color: .hhBlue) }
        if lower == "electric" || lower == "gas_utility"  { return .init(label: "Utilities",    icon: "bolt",                      color: .yellow) }
        if lower == "internet"                            { return .init(label: "Internet",     icon: "wifi",                      color: .hhBlue) }
        if lower == "phone"                               { return .init(label: "Phone",        icon: "phone",                     color: .hhBlue) }
        if lower == "entertainment"                       { return .init(label: "Entertainment",icon: "play.circle",               color: .hhPurple) }
        if lower == "shopping"                            { return .init(label: "Shopping",     icon: "bag",                       color: .hhAccent) }
        if lower == "transportation"                      { return .init(label: "Transport",    icon: "car",                       color: .hhSub) }
        if lower == "health"                              { return .init(label: "Health",       icon: "heart",                     color: .red) }
        if lower == "transfer"                            { return .init(label: "Transfer",     icon: "arrow.left.arrow.right",    color: .hhFaint) }
        return .init(label: "Other", icon: "ellipsis.circle", color: .hhFaint)
    }
}

// MARK: - Financial Store

@Observable
@MainActor
final class FinancialStore {
    var accounts: [FinancialAccount] = []
    var transactions: [FDTransaction] = []
    var recurringTransactions: [FDRecurringTransaction] = []
    var detectedBills: [DetectedBill] = []
    var subscriptions: [DetectedSubscription] = []
    var isLoading = false
    var loadError: String?
    var lastRefreshed: Date?

    var safetyBuffer: Double = 1_500

    // Persisted user decisions (UserDefaults — synced to backend in Phase 4)
    private(set) var confirmedBillIDs: Set<String>
    private(set) var dismissedBillIDs: Set<String>
    private(set) var dismissedSubIDs:  Set<String>

    private let provider: any FinancialDataProvider

    init(provider: any FinancialDataProvider) {
        self.provider = provider
        confirmedBillIDs = Set(UserDefaults.standard.stringArray(forKey: "hh.confirmedBills") ?? [])
        dismissedBillIDs = Set(UserDefaults.standard.stringArray(forKey: "hh.dismissedBills") ?? [])
        dismissedSubIDs  = Set(UserDefaults.standard.stringArray(forKey: "hh.dismissedSubs")  ?? [])
    }

    convenience init() { self.init(provider: ProviderRegistry.financial) }

    // MARK: - Load

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        do {
            async let accts  = provider.fetchAccounts()
            async let txns   = provider.fetchTransactions(from: sixtyDaysAgo, to: Date())
            async let recurs = provider.fetchRecurringTransactions()
            accounts             = try await accts
            transactions         = try await txns
            recurringTransactions = try await recurs
            buildDetectedBills()
            buildSubscriptions()
            lastRefreshed = Date()
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    func refresh() async { await load() }

    // MARK: - User Actions

    func confirmBill(id: String) {
        confirmedBillIDs.insert(id)
        save("hh.confirmedBills", Array(confirmedBillIDs))
        applyBillDecisions()
    }

    func dismissBill(id: String) {
        dismissedBillIDs.insert(id)
        save("hh.dismissedBills", Array(dismissedBillIDs))
        applyBillDecisions()
    }

    func dismissSubscription(id: String) {
        dismissedSubIDs.insert(id)
        save("hh.dismissedSubs", Array(dismissedSubIDs))
        applySubscriptionDecisions()
    }

    // MARK: - Cash Flow Engine

    var checkingBalance: Double {
        accounts.filter { $0.accountType == "checking" }
            .reduce(0) { $0 + ($1.availableBalance ?? $1.balance) }
    }

    var savingsBalance: Double {
        accounts.filter { $0.accountType == "savings" }
            .reduce(0) { $0 + $1.balance }
    }

    var creditOwed: Double {
        accounts.filter { $0.accountType == "credit" }
            .reduce(0) { $0 + $1.balance }  // balance is positive = owed
    }

    var netWorth: Double { checkingBalance + savingsBalance - creditOwed }

    var monthlyIncome: Double {
        let thisMonth = transactions.filter { $0.category == "INCOME" && isThisMonth($0.date) }
        let total = thisMonth.reduce(0) { $0 + abs($1.amount) }  // income is stored as negative
        return total > 0 ? total : estimatedMonthlyIncome
    }

    private var estimatedMonthlyIncome: Double {
        let all = transactions.filter { $0.category == "INCOME" }
        guard !all.isEmpty else { return 0 }
        return all.reduce(0) { $0 + abs($1.amount) } / 2  // 2 months of data
    }

    var committedThisMonth: Double {
        upcomingConfirmedBills.reduce(0) { $0 + $1.amount }
    }

    var safeToSpend: Double {
        max(0, checkingBalance - committedThisMonth - safetyBuffer)
    }

    // MARK: - Bill Views

    var pendingDetectionBills: [DetectedBill] {
        detectedBills.filter { !$0.isConfirmed && !dismissedBillIDs.contains($0.id) }
    }

    var confirmedBills: [DetectedBill] {
        detectedBills.filter { $0.isConfirmed }
    }

    var upcomingConfirmedBills: [DetectedBill] {
        confirmedBills.filter { !$0.isPaidThisMonth }.sorted {
            ($0.predictedNextDate ?? .distantFuture) < ($1.predictedNextDate ?? .distantFuture)
        }
    }

    var paidThisMonthBills: [DetectedBill] {
        confirmedBills.filter { $0.isPaidThisMonth }
    }

    // MARK: - Subscription Views

    var visibleSubscriptions: [DetectedSubscription] {
        subscriptions.filter { !dismissedSubIDs.contains($0.id) }
    }

    var totalSubscriptionCostMonthly: Double {
        visibleSubscriptions.reduce(0) { $0 + $1.amount }
    }

    // MARK: - Phase 8 Insights (computed on demand — no cached state needed)

    var spendingAnomalies: [SpendingAnomaly] {
        InsightsEngine.detectAnomalies(in: transactions)
    }

    var categoryBreakdown: [CategorySpend] {
        InsightsEngine.categoryBreakdown(transactions: transactions)
    }

    var cashFlowForecast: [ForecastPoint] {
        InsightsEngine.cashFlowForecast(
            startBalance: checkingBalance,
            monthlyIncome: monthlyIncome,
            bills: detectedBills,
            daysAhead: 30
        )
    }

    // MARK: - Transactions

    func transactions(for accountID: String) -> [FDTransaction] {
        transactions.filter { $0.accountID == accountID }
            .sorted { $0.date > $1.date }
    }

    var recentTransactions: [FDTransaction] {
        transactions
            .filter { $0.category != "INCOME" && $0.category != "TRANSFER" }
            .sorted { $0.date > $1.date }
            .prefix(20)
            .map { $0 }
    }

    var thisMonthSpending: Double {
        transactions
            .filter { isThisMonth($0.date) && $0.amount > 0 && $0.category != "TRANSFER" && $0.category != "INCOME" }
            .reduce(0) { $0 + $1.amount }
    }

    // MARK: - Detection Logic

    private func buildDetectedBills() {
        let billCategories: Set<String> = ["RENT", "INTERNET", "ELECTRIC", "GAS_UTILITY", "PHONE", "INSURANCE", "MORTGAGE"]
        let minBillAmount = 25.0

        var bills: [DetectedBill] = []
        for r in recurringTransactions where r.amount >= minBillAmount && billCategories.contains(r.category.uppercased()) {
            let paid = isThisMonth(r.lastDate) && r.lastDate >= Calendar.current.startOfDay(for: Date().startOfMonth)
            bills.append(DetectedBill(
                id: r.id,
                merchantName: r.merchantName,
                emoji: billEmoji(for: r.category),
                amount: r.amount,
                frequency: r.frequency,
                lastTransactionDate: r.lastDate,
                predictedNextDate: r.predictedNextDate,
                category: r.category,
                isConfirmed: confirmedBillIDs.contains(r.id),
                isPaidThisMonth: paid
            ))
        }
        detectedBills = bills
    }

    private func buildSubscriptions() {
        let subCategories: Set<String> = ["ENTERTAINMENT", "HEALTH"]
        let maxSubAmount = 100.0

        var subs: [DetectedSubscription] = []
        for r in recurringTransactions where r.amount <= maxSubAmount && (subCategories.contains(r.category.uppercased()) || isKnownSubscription(r.merchantName)) {
            subs.append(DetectedSubscription(
                id: r.id,
                merchantName: r.merchantName,
                emoji: subscriptionEmoji(for: r.merchantName),
                amount: r.amount,
                frequency: r.frequency,
                lastCharge: r.lastDate,
                previousAmount: nil,
                annualCost: annualCost(r.amount, r.frequency)
            ))
        }
        subscriptions = subs
    }

    private func applyBillDecisions() {
        detectedBills = detectedBills.map { bill in
            var b = bill
            b.isConfirmed = confirmedBillIDs.contains(bill.id)
            return b
        }
    }

    private func applySubscriptionDecisions() {
        // subscriptions visibility is filtered dynamically via visibleSubscriptions
    }

    // MARK: - Helpers

    private var sixtyDaysAgo: Date {
        Calendar.current.date(byAdding: .day, value: -60, to: Date()) ?? Date()
    }

    private func isThisMonth(_ date: Date) -> Bool {
        Calendar.current.isDate(date, equalTo: Date(), toGranularity: .month)
    }

    private func isKnownSubscription(_ name: String) -> Bool {
        let known = ["netflix", "spotify", "apple", "amazon prime", "disney", "youtube", "hbo", "goodlife", "gym"]
        return known.contains { name.lowercased().contains($0) }
    }

    private func billEmoji(for category: String) -> String {
        switch category.uppercased() {
        case "RENT", "MORTGAGE":       return "🏠"
        case "INTERNET":               return "📡"
        case "PHONE":                  return "📱"
        case "ELECTRIC", "HYDRO":      return "⚡️"
        case "GAS_UTILITY":            return "🔥"
        case "WATER":                  return "💧"
        case "INSURANCE":              return "🛡️"
        default:                       return "📋"
        }
    }

    private func subscriptionEmoji(for merchant: String) -> String {
        let lower = merchant.lowercased()
        if lower.contains("netflix") { return "🎬" }
        if lower.contains("spotify") { return "🎵" }
        if lower.contains("apple")   { return "🍎" }
        if lower.contains("amazon")  { return "📦" }
        if lower.contains("disney")  { return "🏰" }
        if lower.contains("youtube") { return "▶️" }
        if lower.contains("goodlife") || lower.contains("gym") { return "💪" }
        return "📱"
    }

    private func annualCost(_ amount: Double, _ frequency: String) -> Double {
        switch frequency.lowercased() {
        case "weekly":  return amount * 52
        case "monthly": return amount * 12
        case "annual":  return amount
        default:        return amount * 12
        }
    }

    private func save(_ key: String, _ value: [String]) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

// MARK: - Date Helper

private extension Date {
    var startOfMonth: Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: self)) ?? self
    }
}
