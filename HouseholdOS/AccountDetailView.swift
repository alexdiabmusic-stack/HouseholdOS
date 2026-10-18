import SwiftUI

// MARK: - Account Detail View

struct AccountDetailView: View {
    @Environment(FinancialStore.self) private var store
    let account: FinancialAccount

    @State private var selectedCategory: String? = nil

    private var accountTransactions: [FDTransaction] {
        store.transactions(for: account.id.uuidString.replacingOccurrences(of: "00000000-0000-0000-0002-", with: "acct-").lowercased())
            .sorted { $0.date > $1.date }
    }

    // Fallback: match by account type if ID lookup fails
    private var displayTransactions: [FDTransaction] {
        let byID = store.transactions.filter {
            $0.accountID.contains(account.maskNumber ?? "____")
        }.sorted { $0.date > $1.date }
        return byID.isEmpty ? allAccountTransactions : byID
    }

    private var allAccountTransactions: [FDTransaction] {
        // Use the raw account ID string from the mock provider
        let idMap: [UUID: String] = [
            UUID(uuidString: "00000000-0000-0000-0002-000000000001")!: "acct-td-checking-001",
            UUID(uuidString: "00000000-0000-0000-0002-000000000002")!: "acct-td-savings-001",
            UUID(uuidString: "00000000-0000-0000-0002-000000000003")!: "acct-scotia-visa-001",
        ]
        guard let rawID = idMap[account.id] else { return [] }
        return store.transactions.filter { $0.accountID == rawID }.sorted { $0.date > $1.date }
    }

    private var filteredTransactions: [FDTransaction] {
        guard let cat = selectedCategory else { return allAccountTransactions }
        return allAccountTransactions.filter { $0.category == cat }
    }

    private var categories: [String] {
        Array(Set(allAccountTransactions.map { $0.category })).sorted()
    }

    private var thisMonthSpend: Double {
        allAccountTransactions
            .filter { Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .month) && $0.amount > 0 }
            .reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        ZStack {
            Color.hhBg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    balanceCard
                    if !categories.isEmpty {
                        categoryFilter
                    }
                    transactionsSection
                    Spacer(minLength: 80)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
        }
        .navigationTitle(account.accountName)
        .hhNavTitleStyle(.large)
    }

    // MARK: - Balance Card

    private var balanceCard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(balanceLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.hhSub)
                Text(displayBalance, format: .currency(code: "CAD"))
                    .font(.system(size: 42, weight: .bold))
                    .foregroundColor(.hhInk)
                Text("\(account.institutionName) · ••\(account.maskNumber ?? "••")")
                    .font(.system(size: 13))
                    .foregroundColor(.hhFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            if account.accountType == "credit", let available = account.availableBalance {
                Divider().padding(.horizontal, 20)
                HStack(spacing: 0) {
                    statPill(label: "Owing",      value: account.balance)
                    Divider().frame(height: 32)
                    statPill(label: "Available",  value: available)
                    Divider().frame(height: 32)
                    statPill(label: "Spent (mo)", value: thisMonthSpend)
                }
                .padding(.vertical, 14)
            } else if account.accountType == "checking" {
                Divider().padding(.horizontal, 20)
                HStack(spacing: 0) {
                    statPill(label: "Available", value: account.availableBalance ?? account.balance)
                    Divider().frame(height: 32)
                    statPill(label: "Spent (mo)", value: thisMonthSpend)
                    Divider().frame(height: 32)
                    statPill(label: "Balance",   value: account.balance)
                }
                .padding(.vertical, 14)
            }
        }
        .background(Color.hhCard)
        .cornerRadius(18)
        .shadow(color: Color.hhInk.opacity(0.06), radius: 10, x: 0, y: 3)
    }

    private func statPill(label: String, value: Double) -> some View {
        VStack(spacing: 2) {
            Text(value, format: .currency(code: "CAD").presentation(.standard))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.hhInk)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label).font(.system(size: 10)).foregroundColor(.hhFaint)
        }
        .frame(maxWidth: .infinity)
    }

    private var balanceLabel: String {
        switch account.accountType {
        case "credit":  return "Balance owing"
        case "savings": return "Savings balance"
        default:        return "Available balance"
        }
    }

    private var displayBalance: Double {
        account.accountType == "credit" ? account.balance : (account.availableBalance ?? account.balance)
    }

    // MARK: - Category Filter

    private var categoryFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(label: "All", category: nil)
                ForEach(categories, id: \.self) { cat in
                    filterChip(
                        label: TxCategory.from(plaidCategory: cat, merchantName: cat).label,
                        category: cat
                    )
                }
            }
            .padding(.horizontal, 1)
        }
    }

    private func filterChip(label: String, category: String?) -> some View {
        Button {
            withAnimation(.spring(response: 0.3)) {
                selectedCategory = selectedCategory == category ? nil : category
            }
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(selectedCategory == category ? .white : .hhSub)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selectedCategory == category ? Color.hhAccent : Color.hhCard)
                .cornerRadius(20)
                .shadow(color: Color.hhInk.opacity(selectedCategory == category ? 0 : 0.04), radius: 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Transactions

    private var transactionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Transactions", subtitle: "\(filteredTransactions.count)")

            if filteredTransactions.isEmpty {
                Text("No transactions in this category")
                    .font(.system(size: 14))
                    .foregroundColor(.hhFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(filteredTransactions) { txn in
                        TransactionRow(txn: txn)
                        if txn.id != filteredTransactions.last?.id {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(Color.hhCard)
                .cornerRadius(18)
                .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
            }
        }
    }
}

// MARK: - All Transactions View

struct AllTransactionsView: View {
    @Environment(FinancialStore.self) private var store
    @State private var searchText = ""
    @State private var selectedCategory: String? = nil

    private var filteredTransactions: [FDTransaction] {
        var txns = store.transactions.sorted { $0.date > $1.date }
        if let cat = selectedCategory {
            txns = txns.filter { $0.category == cat }
        }
        if !searchText.isEmpty {
            txns = txns.filter {
                ($0.merchantName ?? $0.description).localizedCaseInsensitiveContains(searchText) ||
                $0.description.localizedCaseInsensitiveContains(searchText)
            }
        }
        return txns
    }

    private var allCategories: [String] {
        Array(Set(store.transactions.map { $0.category })).sorted()
    }

    private var totalSpend: Double {
        filteredTransactions.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        ZStack {
            Color.hhBg.ignoresSafeArea()
            VStack(spacing: 0) {
                // Search + filter
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.hhFaint)
                        TextField("Search transactions", text: $searchText)
                            .font(.system(size: 15))
                    }
                    .padding(12)
                    .background(Color.hhCard)
                    .cornerRadius(12)
                    .padding(.horizontal, 20)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            filterChip(label: "All", category: nil)
                            ForEach(allCategories, id: \.self) { cat in
                                filterChip(label: TxCategory.from(plaidCategory: cat, merchantName: cat).label, category: cat)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 8)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        if !filteredTransactions.isEmpty {
                            HStack {
                                Text("\(filteredTransactions.count) transactions")
                                    .font(.system(size: 12))
                                    .foregroundColor(.hhFaint)
                                Spacer()
                                if totalSpend > 0 {
                                    Text(totalSpend, format: .currency(code: "CAD"))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.hhInk)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)
                        }

                        VStack(spacing: 0) {
                            ForEach(filteredTransactions) { txn in
                                TransactionRow(txn: txn)
                                if txn.id != filteredTransactions.last?.id {
                                    Divider().padding(.leading, 56)
                                }
                            }
                        }
                        .background(Color.hhCard)
                        .cornerRadius(18)
                        .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
                        .padding(.horizontal, 20)

                        Spacer(minLength: 80)
                    }
                }
            }
        }
        .navigationTitle("Transactions")
        .hhNavTitleStyle(.large)
    }

    private func filterChip(label: String, category: String?) -> some View {
        Button {
            withAnimation(.spring(response: 0.3)) {
                selectedCategory = selectedCategory == category ? nil : category
            }
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(selectedCategory == category ? .white : .hhSub)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selectedCategory == category ? Color.hhAccent : Color.hhCard)
                .cornerRadius(20)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        AccountDetailView(account: PlaidSandboxProvider.accounts[0])
    }
    .environment(FinancialStore(provider: PlaidSandboxProvider()))
}
