import Foundation

// MARK: - Plaid Sandbox Provider
// Realistic Canadian mock data that mirrors the shape of real Plaid API responses.
// Swap ProviderRegistry.financial for a real PlaidProvider when backend + credentials are ready.

struct PlaidSandboxProvider: FinancialDataProvider {
    let name = "Plaid (Sandbox)"
    let isConnected = true

    func fetchAccounts() async throws -> [FinancialAccount] {
        try await delay(0.6)
        return Self.accounts
    }

    func fetchTransactions(from: Date, to: Date) async throws -> [FDTransaction] {
        try await delay(0.8)
        return Self.transactions.filter { $0.date >= from && $0.date <= to }
    }

    func fetchRecurringTransactions() async throws -> [FDRecurringTransaction] {
        try await delay(0.4)
        return Self.recurring
    }

    private func delay(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - Accounts

extension PlaidSandboxProvider {
    static let accounts: [FinancialAccount] = [
        FinancialAccount(
            id: UUID(uuidString: "00000000-0000-0000-0002-000000000001")!,
            institutionName: "TD Bank",
            accountName: "Everyday Chequing",
            accountType: "checking",
            balance: 4_284.50,
            availableBalance: 4_134.50,
            maskNumber: "4521"
        ),
        FinancialAccount(
            id: UUID(uuidString: "00000000-0000-0000-0002-000000000002")!,
            institutionName: "TD Bank",
            accountName: "High Interest Savings",
            accountType: "savings",
            balance: 8_420.00,
            availableBalance: 8_420.00,
            maskNumber: "9834"
        ),
        FinancialAccount(
            id: UUID(uuidString: "00000000-0000-0000-0002-000000000003")!,
            institutionName: "Scotiabank",
            accountName: "Scotia Momentum Visa",
            accountType: "credit",
            balance: 1_847.33,   // positive = amount owed
            availableBalance: 8_152.67,
            maskNumber: "7721"
        ),
    ]
}

// MARK: - Recurring Transactions

extension PlaidSandboxProvider {
    static let recurring: [FDRecurringTransaction] = [
        FDRecurringTransaction(
            id: "recur-rent-001",
            amount: 2_900.00,
            frequency: "monthly",
            merchantName: "Rent E-Transfer",
            category: "RENT",
            lastDate: d(-2),
            predictedNextDate: d(28)
        ),
        FDRecurringTransaction(
            id: "recur-rogers-internet-001",
            amount: 89.99,
            frequency: "monthly",
            merchantName: "Rogers Internet",
            category: "INTERNET",
            lastDate: d(-8),
            predictedNextDate: d(22)
        ),
        FDRecurringTransaction(
            id: "recur-hydro-001",
            amount: 94.18,
            frequency: "monthly",
            merchantName: "Hydro Ottawa",
            category: "ELECTRIC",
            lastDate: d(-12),
            predictedNextDate: d(18)
        ),
        FDRecurringTransaction(
            id: "recur-enbridge-001",
            amount: 127.50,
            frequency: "monthly",
            merchantName: "Enbridge Gas",
            category: "GAS_UTILITY",
            lastDate: d(-5),
            predictedNextDate: d(25)
        ),
        FDRecurringTransaction(
            id: "recur-rogers-mobile-001",
            amount: 65.00,
            frequency: "monthly",
            merchantName: "Rogers Mobile",
            category: "PHONE",
            lastDate: d(-20),
            predictedNextDate: d(10)
        ),
        FDRecurringTransaction(
            id: "recur-netflix-001",
            amount: 17.99,
            frequency: "monthly",
            merchantName: "Netflix",
            category: "ENTERTAINMENT",
            lastDate: d(-3),
            predictedNextDate: d(27)
        ),
        FDRecurringTransaction(
            id: "recur-spotify-001",
            amount: 11.99,
            frequency: "monthly",
            merchantName: "Spotify",
            category: "ENTERTAINMENT",
            lastDate: d(-15),
            predictedNextDate: d(15)
        ),
        FDRecurringTransaction(
            id: "recur-apple-001",
            amount: 4.99,
            frequency: "monthly",
            merchantName: "Apple iCloud",
            category: "ENTERTAINMENT",
            lastDate: d(-7),
            predictedNextDate: d(23)
        ),
        FDRecurringTransaction(
            id: "recur-goodlife-001",
            amount: 49.99,
            frequency: "monthly",
            merchantName: "GoodLife Fitness",
            category: "HEALTH",
            lastDate: d(-10),
            predictedNextDate: d(20)
        ),
    ]
}

// MARK: - Transactions (60 days)

extension PlaidSandboxProvider {
    // Plaid convention: positive = debit (money out), negative = credit (money in / payroll)
    static let transactions: [FDTransaction] = [
        // Income
        t(id: "txn-pay-aug",  days: -10, amount: -4_120.00, desc: "ADP Payroll",     cat: "INCOME",        merchant: "Employer Payroll",  acct: "acct-td-checking-001"),
        t(id: "txn-pay-jul",  days: -41, amount: -4_120.00, desc: "ADP Payroll",     cat: "INCOME",        merchant: "Employer Payroll",  acct: "acct-td-checking-001"),

        // Housing
        t(id: "txn-rent-aug", days: -2,  amount:  2_900.00, desc: "E-Transfer Sent", cat: "RENT",          merchant: "Rent E-Transfer",   acct: "acct-td-checking-001"),
        t(id: "txn-rent-jul", days: -32, amount:  2_900.00, desc: "E-Transfer Sent", cat: "RENT",          merchant: "Rent E-Transfer",   acct: "acct-td-checking-001"),

        // Utilities
        t(id: "txn-hydro-aug",   days: -12, amount:  94.18, desc: "Hydro Ottawa",      cat: "ELECTRIC",      merchant: "Hydro Ottawa",      acct: "acct-td-checking-001"),
        t(id: "txn-rogers-aug",  days: -8,  amount:  89.99, desc: "Rogers Comm",       cat: "INTERNET",      merchant: "Rogers Internet",   acct: "acct-td-checking-001"),
        t(id: "txn-enbridge-aug",days: -5,  amount: 127.50, desc: "Enbridge Gas Dist", cat: "GAS_UTILITY",   merchant: "Enbridge Gas",      acct: "acct-td-checking-001"),
        t(id: "txn-phone-aug",   days: -20, amount:  65.00, desc: "Rogers Mobile",     cat: "PHONE",         merchant: "Rogers Mobile",     acct: "acct-td-checking-001"),

        // Groceries
        t(id: "txn-groc-1", days: -2,  amount:  87.42, desc: "Loblaws #0334",    cat: "GROCERIES",    merchant: "Loblaws",           acct: "acct-scotia-visa-001"),
        t(id: "txn-groc-2", days: -9,  amount: 112.33, desc: "PC Express",       cat: "GROCERIES",    merchant: "Real Canadian Superstore", acct: "acct-scotia-visa-001"),
        t(id: "txn-groc-3", days: -16, amount:  63.21, desc: "Loblaws #0334",    cat: "GROCERIES",    merchant: "Loblaws",           acct: "acct-scotia-visa-001"),
        t(id: "txn-groc-4", days: -33, amount:  98.77, desc: "Sobeys #1021",     cat: "GROCERIES",    merchant: "Sobeys",            acct: "acct-scotia-visa-001"),
        t(id: "txn-groc-5", days: -44, amount:  44.50, desc: "Whole Foods Mkt",  cat: "GROCERIES",    merchant: "Whole Foods",       acct: "acct-scotia-visa-001"),

        // Restaurants & Coffee
        t(id: "txn-rest-1", days: -3,  amount:  89.50, desc: "The Keg Steakhouse", cat: "FOOD_AND_DRINK", merchant: "The Keg",        acct: "acct-scotia-visa-001"),
        t(id: "txn-rest-2", days: -5,  amount:   7.35, desc: "Tim Hortons #2341",  cat: "FOOD_AND_DRINK", merchant: "Tim Hortons",    acct: "acct-scotia-visa-001"),
        t(id: "txn-rest-3", days: -14, amount:  23.45, desc: "Chipotle",           cat: "FOOD_AND_DRINK", merchant: "Chipotle",       acct: "acct-scotia-visa-001"),
        t(id: "txn-rest-4", days: -17, amount:  54.80, desc: "Town Restaurant",    cat: "FOOD_AND_DRINK", merchant: "Town Restaurant",acct: "acct-scotia-visa-001"),
        t(id: "txn-rest-5", days: -29, amount:   6.25, desc: "Tim Hortons",        cat: "FOOD_AND_DRINK", merchant: "Tim Hortons",    acct: "acct-scotia-visa-001"),
        t(id: "txn-rest-6", days: -35, amount:  41.90, desc: "Pizza Hut",          cat: "FOOD_AND_DRINK", merchant: "Pizza Hut",      acct: "acct-scotia-visa-001"),

        // Entertainment / Subscriptions
        t(id: "txn-netflix",   days: -3,  amount: 17.99, desc: "Netflix",   cat: "ENTERTAINMENT", merchant: "Netflix",   acct: "acct-scotia-visa-001"),
        t(id: "txn-spotify",   days: -15, amount: 11.99, desc: "Spotify",   cat: "ENTERTAINMENT", merchant: "Spotify",   acct: "acct-scotia-visa-001"),
        t(id: "txn-apple",     days: -7,  amount:  4.99, desc: "Apple.com", cat: "ENTERTAINMENT", merchant: "Apple iCloud", acct: "acct-scotia-visa-001"),
        t(id: "txn-cineplex",  days: -18, amount: 32.50, desc: "Cineplex",  cat: "ENTERTAINMENT", merchant: "Cineplex",  acct: "acct-scotia-visa-001"),

        // Shopping
        t(id: "txn-amazon-1",  days: -4,  amount:  67.43, desc: "Amazon.ca",      cat: "SHOPPING", merchant: "Amazon",        acct: "acct-scotia-visa-001"),
        t(id: "txn-amazon-2",  days: -31, amount: 124.99, desc: "Amazon.ca",      cat: "SHOPPING", merchant: "Amazon",        acct: "acct-scotia-visa-001"),
        t(id: "txn-cantire",   days: -11, amount:  43.21, desc: "Canadian Tire",  cat: "SHOPPING", merchant: "Canadian Tire", acct: "acct-scotia-visa-001"),

        // Health & Fitness
        t(id: "txn-goodlife",  days: -10, amount: 49.99, desc: "GoodLife Fitness", cat: "HEALTH", merchant: "GoodLife Fitness", acct: "acct-scotia-visa-001"),
        t(id: "txn-shoppers",  days: -14, amount: 24.50, desc: "Shoppers Drug",    cat: "HEALTH", merchant: "Shoppers Drug Mart", acct: "acct-scotia-visa-001"),

        // Transportation
        t(id: "txn-uber",    days: -2,  amount: 18.50, desc: "Uber",          cat: "TRANSPORTATION", merchant: "Uber",           acct: "acct-scotia-visa-001"),
        t(id: "txn-petro",   days: -7,  amount: 72.44, desc: "Petro-Canada",  cat: "TRANSPORTATION", merchant: "Petro-Canada",   acct: "acct-scotia-visa-001"),
        t(id: "txn-octrans", days: -30, amount: 116.50, desc: "OC Transpo",   cat: "TRANSPORTATION", merchant: "OC Transpo",     acct: "acct-td-checking-001"),

        // Credit card payment
        t(id: "txn-cc-pay",  days: -15, amount: -1_200.00, desc: "Visa Payment", cat: "TRANSFER", merchant: "Scotiabank Visa", acct: "acct-td-checking-001"),

        // Phase 8 anomaly demo: Loblaws unusually large charge (4.5× normal avg of $63.21)
        t(id: "txn-groc-anomaly", days: -3, amount: 287.55, desc: "Loblaws #0334 — Restock", cat: "GROCERIES", merchant: "Loblaws", acct: "acct-scotia-visa-001"),

        // Phase 8 anomaly demo: Amazon possible duplicate ($67.43 twice within 5 days)
        t(id: "txn-amazon-dup", days: -7, amount: 67.43, desc: "Amazon.ca", cat: "SHOPPING", merchant: "Amazon", acct: "acct-scotia-visa-001"),
    ]

    private static func t(id: String, days: Int, amount: Double, desc: String, cat: String, merchant: String, acct: String) -> FDTransaction {
        FDTransaction(id: id, date: d(days), amount: amount, description: desc, category: cat, merchantName: merchant, accountID: acct)
    }

    static func d(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }
}
