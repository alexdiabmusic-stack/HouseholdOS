import Foundation

// MARK: - Phase 8 Insight Types

struct SpendingAnomaly: Identifiable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case unusuallyLarge
        case possibleDuplicate
    }
    enum Severity: Sendable { case warning, alert }

    let id: String
    let kind: Kind
    let severity: Severity
    let merchantName: String
    let amount: Double
    let date: Date
    let message: String
    let historicalAverage: Double?
}

struct CategorySpend: Identifiable, Sendable {
    let id: String          // plaid category string key
    let category: String
    let amountThisMonth: Double
    let amountLastMonth: Double
    let transactionCount: Int

    var changePercent: Double? {
        guard amountLastMonth > 0 else { return nil }
        return (amountThisMonth - amountLastMonth) / amountLastMonth * 100
    }
    var isUp:   Bool { (changePercent ?? 0) > 8 }
    var isDown: Bool { (changePercent ?? 0) < -8 }

    var displayName: String {
        switch category.uppercased() {
        case "GROCERIES":           return "Groceries"
        case "FOOD_AND_DRINK":      return "Dining"
        case "SHOPPING":            return "Shopping"
        case "ENTERTAINMENT":       return "Entertainment"
        case "TRANSPORTATION":      return "Transport"
        case "HEALTH":              return "Health"
        case "RENT", "MORTGAGE":    return "Housing"
        case "ELECTRIC", "HYDRO":   return "Utilities"
        case "INTERNET":            return "Internet"
        case "PHONE":               return "Phone"
        default:
            return category.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct ForecastPoint: Identifiable, Sendable {
    let id: String
    let date: Date
    let projectedBalance: Double
    let isProjected: Bool
}

// MARK: - Insights Engine (pure computation — no stored state)

enum InsightsEngine {

    // MARK: Anomaly Detection
    //
    // Baseline window: transactions 14–60 days old (older than 2 weeks).
    // "Unusual" = recent charge > 2× baseline merchant average AND > $50.
    // "Possible duplicate" = same merchant + amount within 5 days.
    // One alert fires per merchant × kind to avoid alert fatigue.

    static func detectAnomalies(in transactions: [FDTransaction]) -> [SpendingAnomaly] {
        let cal = Calendar.current
        let now = Date()
        let recentCutoff   = cal.date(byAdding: .day, value: -14, to: now) ?? now
        let baselineCutoff = cal.date(byAdding: .day, value: -60, to: now) ?? now

        let spending = transactions.filter { $0.amount > 0 && $0.category != "INCOME" && $0.category != "TRANSFER" }
        let baseline = spending.filter { $0.date < recentCutoff && $0.date >= baselineCutoff }
        let recent   = spending.filter { $0.date >= recentCutoff }

        let baselineByMerchant = Dictionary(grouping: baseline) { $0.merchantName ?? $0.description }

        var anomalies: [SpendingAnomaly] = []
        var seen = Set<String>()

        // Unusually large charges vs. historical baseline
        for txn in recent {
            let merchant = txn.merchantName ?? txn.description
            let history  = baselineByMerchant[merchant] ?? []
            guard !history.isEmpty else { continue }
            let avg = history.reduce(0) { $0 + $1.amount } / Double(history.count)
            guard txn.amount > avg * 2.0, txn.amount > 50 else { continue }
            let key = "large-\(merchant)"
            guard seen.insert(key).inserted else { continue }
            let pct = Int((txn.amount / avg - 1) * 100)
            anomalies.append(SpendingAnomaly(
                id: "anomaly-large-\(txn.id)",
                kind: .unusuallyLarge,
                severity: txn.amount > avg * 4 ? .alert : .warning,
                merchantName: merchant,
                amount: txn.amount,
                date: txn.date,
                message: "\(pct)% above your usual \(avg.formatted(.currency(code: "CAD"))) at \(merchant).",
                historicalAverage: avg
            ))
        }

        // Possible duplicates within the recent window
        let sortedRecent = recent.sorted { $0.date < $1.date }
        for i in 0..<sortedRecent.count {
            for j in (i + 1)..<sortedRecent.count {
                let a = sortedRecent[i], b = sortedRecent[j]
                let days = cal.dateComponents([.day], from: a.date, to: b.date).day ?? 0
                guard days <= 5 else { break }
                let ma = a.merchantName ?? a.description
                let mb = b.merchantName ?? b.description
                guard ma == mb, abs(a.amount - b.amount) < 0.01, a.amount > 20 else { continue }
                let key = "dup-\(ma)"
                guard seen.insert(key).inserted else { continue }
                anomalies.append(SpendingAnomaly(
                    id: "anomaly-dup-\(b.id)",
                    kind: .possibleDuplicate,
                    severity: .warning,
                    merchantName: ma,
                    amount: b.amount,
                    date: b.date,
                    message: "\(b.amount.formatted(.currency(code: "CAD"))) at \(ma) appeared twice within \(days) day\(days == 1 ? "" : "s").",
                    historicalAverage: nil
                ))
            }
        }

        // Alerts first, then warnings
        return anomalies.sorted { $0.severity == .alert && $1.severity != .alert }
    }

    // MARK: Category Breakdown

    static func categoryBreakdown(transactions: [FDTransaction]) -> [CategorySpend] {
        let cal = Calendar.current
        let now = Date()
        let thisMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let lastMonthStart = cal.date(byAdding: .month, value: -1, to: thisMonthStart) ?? thisMonthStart

        // Exclude housing/transfers from spending breakdown (shown in bills section)
        let spending = transactions.filter {
            $0.amount > 0
            && $0.category != "INCOME"
            && $0.category != "TRANSFER"
            && $0.category != "RENT"
            && $0.category != "MORTGAGE"
        }
        let thisMonth = spending.filter { $0.date >= thisMonthStart }
        let lastMonth = spending.filter { $0.date >= lastMonthStart && $0.date < thisMonthStart }

        let thisGrouped = Dictionary(grouping: thisMonth) { $0.category }
        let lastGrouped = Dictionary(grouping: lastMonth) { $0.category }

        return Set(thisGrouped.keys).map { cat in
            CategorySpend(
                id: cat,
                category: cat,
                amountThisMonth: thisGrouped[cat]?.reduce(0) { $0 + $1.amount } ?? 0,
                amountLastMonth: lastGrouped[cat]?.reduce(0) { $0 + $1.amount } ?? 0,
                transactionCount: thisGrouped[cat]?.count ?? 0
            )
        }
        .filter { $0.amountThisMonth > 1 }
        .sorted { $0.amountThisMonth > $1.amountThisMonth }
    }

    // MARK: Cash Flow Forecast
    //
    // Projects `daysAhead` days starting from `startBalance`.
    // Income timing is unknown unless supplied explicitly; never invent paydays.
    // Bills deducted on their predicted due dates.
    // The first point (offset 0 = today) is marked isProjected = false.

    static func cashFlowForecast(
        startBalance: Double,
        monthlyIncome: Double,
        bills: [DetectedBill],
        daysAhead: Int = 30,
        incomeEvents: [(date: Date, amount: Double)] = [],
        dailySpending: Double = 0
    ) -> [ForecastPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // monthlyIncome is retained for source compatibility; no pay dates are inferred.
        _ = monthlyIncome
        var balance = startBalance
        var points: [ForecastPoint] = []

        for offset in 0...max(0, daysAhead) {
            guard let date = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            do {
                balance += incomeEvents.filter { cal.isDate($0.date, inSameDayAs: date) }.reduce(0) { $0 + $1.amount }
                if offset > 0 { balance -= max(0, dailySpending) }
                for bill in bills.filter({ !$0.isPaidThisMonth }) {
                    if let next = bill.predictedNextDate, cal.isDate(next, inSameDayAs: date) {
                        balance -= bill.amount
                    }
                }
            }
            points.append(ForecastPoint(
                id: "fc-\(offset)",
                date: date,
                projectedBalance: balance,
                isProjected: offset > 0
            ))
        }
        return points
    }
}
