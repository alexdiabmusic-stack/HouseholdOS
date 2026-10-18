import SwiftUI

// MARK: - Money View

struct MoneyView: View {
    @Environment(FinancialStore.self) private var store
    @Environment(PaymentStore.self) private var paymentStore
    @Environment(RewardsStore.self) private var rewardsStore

    @State private var showBillDetection = false
    @State private var showSubscriptions = false
    @State private var showAllTransactions = false
    @State private var showConnectSheet = false
    @State private var selectedBillForPayment: DetectedBill? = nil
    @State private var showAutoPaySettings = false
    @State private var showPaymentHistory = false
    @State private var showRewards = false
    @State private var showInsights = false

    var body: some View {
        ZStack {
            Color.hhBg.ignoresSafeArea()

            if store.isLoading && store.accounts.isEmpty {
                loadingState
            } else if !FeatureFlags.financialConnections {
                disconnectedState
            } else {
                mainContent
            }
        }
        .navigationTitle("Money")
        .hhNavTitleStyle(.large)
        .refreshable { await store.refresh() }
        .sheet(isPresented: $showBillDetection) {
            BillDetectionSheet()
                .environment(store)
        }
        .sheet(isPresented: $showSubscriptions) {
            SubscriptionManagerView()
                .environment(store)
        }
        .navigationDestination(isPresented: $showAllTransactions) {
            AllTransactionsView()
                .environment(store)
        }
        .sheet(isPresented: $showConnectSheet) {
            ConnectAccountsSheet()
        }
        .sheet(item: $selectedBillForPayment) { bill in
            BillPaySheet(bill: bill)
                .environment(store)
                .environment(paymentStore)
        }
        .sheet(isPresented: $showAutoPaySettings) {
            SafeAutoPaySettingsView()
                .environment(store)
                .environment(paymentStore)
        }
        .navigationDestination(isPresented: $showPaymentHistory) {
            PaymentHistoryView()
                .environment(paymentStore)
        }
        .navigationDestination(isPresented: $showRewards) {
            RewardsView()
                .environment(rewardsStore)
        }
        .navigationDestination(isPresented: $showInsights) {
            InsightsView()
                .environment(store)
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                if FeatureFlags.sandboxBannerVisible {
                    sandboxBanner
                }
                safeToSpendCard
                accountsSection
                if !store.pendingDetectionBills.isEmpty {
                    billDetectionBanner
                }
                if !store.upcomingConfirmedBills.isEmpty {
                    upcomingBillsSection
                }
                if FeatureFlags.vopayPayments {
                    safeAutoPaySection
                }
                if !store.paidThisMonthBills.isEmpty {
                    paidBillsSection
                }
                if FeatureFlags.vopayPayments && !paymentStore.allPayments.isEmpty {
                    paymentHistoryRow
                }
                subscriptionsSection
                if FeatureFlags.spendingInsights {
                    insightsCard
                }
                if FeatureFlags.householdRewards {
                    rewardsCard
                }
                recentTransactionsSection
                Spacer(minLength: 80)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }

    // MARK: - Loading

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.3)
                .tint(.hhAccent)
            Text("Loading your finances…")
                .font(.system(size: 14))
                .foregroundColor(.hhFaint)
        }
    }

    // MARK: - Disconnected

    private var disconnectedState: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                connectAccountsBanner
                Spacer(minLength: 80)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }

    // MARK: - Sandbox Banner

    private var sandboxBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "flask.fill").font(.system(size: 12))
            Text("Sandbox data — connect real accounts to see your actual finances")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(.hhAccent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.hhAccent.opacity(0.08))
        .cornerRadius(10)
    }

    // MARK: - Safe to Spend

    private var safeToSpendCard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Safe to spend")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.hhSub)
                Text(store.safeToSpend, format: .currency(code: "CAD"))
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(.hhInk)
                    .contentTransition(.numericText())
                Text("Available this month")
                    .font(.system(size: 12))
                    .foregroundColor(.hhFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider().padding(.horizontal, 20)

            HStack(spacing: 0) {
                moneyPill(label: "Income",    value: store.monthlyIncome,     color: .hhGreen, prefix: "+")
                Divider().frame(height: 36)
                moneyPill(label: "Committed", value: store.committedThisMonth, color: .hhInk,  prefix: "−")
                Divider().frame(height: 36)
                moneyPill(label: "Buffer",    value: store.safetyBuffer,       color: .hhFaint, prefix: "−")
            }
            .padding(.vertical, 14)
        }
        .background(Color.hhCard)
        .cornerRadius(20)
        .shadow(color: Color.hhInk.opacity(0.06), radius: 12, x: 0, y: 4)
    }

    private func moneyPill(label: String, value: Double, color: Color, prefix: String) -> some View {
        VStack(spacing: 3) {
            Text("\(prefix)\(value, format: .currency(code: "CAD").presentation(.standard))")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.hhFaint)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Accounts

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Accounts")
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(store.netWorth, format: .currency(code: "CAD"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.hhInk)
                    Text("net worth")
                        .font(.system(size: 10))
                        .foregroundColor(.hhFaint)
                }
            }

            VStack(spacing: 0) {
                ForEach(store.accounts) { account in
                    NavigationLink(destination: AccountDetailView(account: account).environment(store)) {
                        AccountRow(account: account)
                    }
                    .buttonStyle(.plain)

                    if account.id != store.accounts.last?.id {
                        Divider().padding(.leading, 64)
                    }
                }
            }
            .background(Color.hhCard)
            .cornerRadius(18)
            .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
        }
    }

    // MARK: - Bill Detection Banner

    private var billDetectionBanner: some View {
        Button { showBillDetection = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20))
                    .foregroundColor(.hhAccent)
                    .frame(width: 44, height: 44)
                    .background(Color.hhAccent.opacity(0.1))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("We found \(store.pendingDetectionBills.count) recurring payment\(store.pendingDetectionBills.count == 1 ? "" : "s")")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.hhInk)
                    Text("Confirm them to track your bills automatically")
                        .font(.system(size: 13))
                        .foregroundColor(.hhSub)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.hhFaint)
            }
            .padding(16)
            .background(Color.hhCard)
            .cornerRadius(18)
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.hhAccent.opacity(0.25), lineWidth: 1.5)
            )
            .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Upcoming Bills

    private var upcomingBillsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Upcoming bills", subtitle: "\(store.upcomingConfirmedBills.count) bills")
            VStack(spacing: 10) {
                ForEach(store.upcomingConfirmedBills) { bill in
                    if FeatureFlags.vopayPayments {
                        PayableBillRow(
                            bill: bill,
                            isScheduled: paymentStore.hasScheduledPayment(forBillID: bill.id)
                        ) { selectedBillForPayment = bill }
                    } else {
                        DetectedBillRow(bill: bill)
                    }
                }
            }
        }
    }

    // MARK: - Safe AutoPay

    private var safeAutoPaySection: some View {
        Button { showAutoPaySettings = true } label: {
            HStack(spacing: 14) {
                Image(systemName: paymentStore.safeAutoPayEnabled ? "bolt.circle.fill" : "bolt.circle")
                    .font(.system(size: 20))
                    .foregroundColor(.hhGreen)
                    .frame(width: 44, height: 44)
                    .background(Color.hhGreen.opacity(0.1))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Safe AutoPay")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.hhInk)
                    Text(paymentStore.safeAutoPayEnabled
                         ? "\(paymentStore.enabledAutoPayRulesCount) bill\(paymentStore.enabledAutoPayRulesCount == 1 ? "" : "s") configured"
                         : "Set up automatic bill payments")
                        .font(.system(size: 13))
                        .foregroundColor(.hhSub)
                }
                Spacer()
                if paymentStore.safeAutoPayEnabled {
                    Text("ON")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.hhGreen)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.hhGreen.opacity(0.12))
                        .cornerRadius(6)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.hhFaint)
            }
            .padding(16)
            .background(Color.hhCard)
            .cornerRadius(18)
            .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Paid Bills

    private var paidBillsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Paid this month", subtitle: "\(store.paidThisMonthBills.count)")
            VStack(spacing: 10) {
                ForEach(store.paidThisMonthBills) { bill in
                    DetectedBillRow(bill: bill)
                }
            }
        }
    }

    // MARK: - Payment History Row

    private var paymentHistoryRow: some View {
        Button { showPaymentHistory = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 18))
                    .foregroundColor(.hhBlue)
                    .frame(width: 42, height: 42)
                    .background(Color.hhBlue.opacity(0.1))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Payment History")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.hhInk)
                    Text("\(paymentStore.allPayments.count) payment\(paymentStore.allPayments.count == 1 ? "" : "s")")
                        .font(.system(size: 13))
                        .foregroundColor(.hhSub)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.hhFaint)
            }
            .padding(16)
            .background(Color.hhCard)
            .cornerRadius(18)
            .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Subscriptions

    private var subscriptionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Subscriptions")
                Spacer()
                Button { showSubscriptions = true } label: {
                    Text("Manage")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.hhAccent)
                }
            }

            VStack(spacing: 0) {
                ForEach(store.visibleSubscriptions.prefix(4)) { sub in
                    SubscriptionRow(sub: sub)
                    if sub.id != store.visibleSubscriptions.prefix(4).last?.id {
                        Divider().padding(.leading, 64)
                    }
                }

                if store.visibleSubscriptions.count > 4 {
                    Divider().padding(.leading, 64)
                    HStack {
                        Text("\(store.visibleSubscriptions.count - 4) more subscriptions")
                            .font(.system(size: 13))
                            .foregroundColor(.hhSub)
                        Spacer()
                        Text(store.totalSubscriptionCostMonthly, format: .currency(code: "CAD"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.hhInk)
                        Text("/ mo")
                            .font(.system(size: 11))
                            .foregroundColor(.hhFaint)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
            .background(Color.hhCard)
            .cornerRadius(18)
            .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)

            HStack {
                Text("Total")
                    .font(.system(size: 13))
                    .foregroundColor(.hhFaint)
                Spacer()
                Text(store.totalSubscriptionCostMonthly, format: .currency(code: "CAD"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.hhInk)
                Text("/ month ·")
                    .font(.system(size: 11))
                    .foregroundColor(.hhFaint)
                Text(store.totalSubscriptionCostMonthly * 12, format: .currency(code: "CAD"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.hhInk)
                Text("/ year")
                    .font(.system(size: 11))
                    .foregroundColor(.hhFaint)
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Smart Insights Card

    private var insightsCard: some View {
        Button { showInsights = true } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.hhAccent.opacity(0.1))
                        .frame(width: 42, height: 42)
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 18))
                        .foregroundColor(.hhAccent)
                    if !store.spendingAnomalies.isEmpty {
                        Text("\(store.spendingAnomalies.count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 16, height: 16)
                            .background(Color.orange)
                            .clipShape(Circle())
                            .offset(x: 13, y: -13)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart Insights")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.hhInk)
                    if store.spendingAnomalies.isEmpty {
                        Text("No unusual activity · category breakdown · 30-day forecast")
                            .font(.system(size: 13))
                            .foregroundColor(.hhSub)
                    } else {
                        let n = store.spendingAnomalies.count
                        Text("\(n) unusual transaction\(n == 1 ? "" : "s") detected")
                            .font(.system(size: 13))
                            .foregroundColor(.orange)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.hhFaint)
            }
            .padding(16)
            .background(Color.hhCard)
            .cornerRadius(18)
            .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Rewards Card

    private var rewardsCard: some View {
        Button { showRewards = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "sparkle")
                    .font(.system(size: 18))
                    .foregroundColor(.hhGreen)
                    .frame(width: 42, height: 42)
                    .background(Color.hhGreen.opacity(0.1))
                    .cornerRadius(12)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Household Rewards")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.hhInk)
                    Group {
                        if rewardsStore.isLoadingBalance {
                            Text("Loading…").foregroundColor(.hhFaint)
                        } else if rewardsStore.hasBalance {
                            HStack(spacing: 4) {
                                Text(rewardsStore.balance.confirmed, format: .currency(code: "CAD"))
                                    .foregroundColor(.hhGreen)
                                Text("earned · \(rewardsStore.offers.count) active offers")
                                    .foregroundColor(.hhSub)
                            }
                        } else {
                            Text("\(rewardsStore.offers.count) active offers · earns automatically")
                                .foregroundColor(.hhSub)
                        }
                    }
                    .font(.system(size: 13))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.hhFaint)
            }
            .padding(16)
            .background(Color.hhCard)
            .cornerRadius(18)
            .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recent Transactions

    private var recentTransactionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Recent spending")
                Spacer()
                Button { showAllTransactions = true } label: {
                    Text("See all")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.hhAccent)
                }
            }

            VStack(spacing: 0) {
                ForEach(store.recentTransactions.prefix(8)) { txn in
                    TransactionRow(txn: txn)
                    if txn.id != store.recentTransactions.prefix(8).last?.id {
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .background(Color.hhCard)
            .cornerRadius(18)
            .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
        }
    }

    // MARK: - Connect Accounts Banner

    private var connectAccountsBanner: some View {
        Button { showConnectSheet = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "building.columns")
                    .font(.system(size: 20))
                    .foregroundColor(.hhBlue)
                    .frame(width: 44, height: 44)
                    .background(Color.hhBlue.opacity(0.1))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect your accounts")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.hhInk)
                    Text("See real balances, bills, and transactions")
                        .font(.system(size: 13))
                        .foregroundColor(.hhSub)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.hhFaint)
            }
            .padding(16)
            .background(Color.hhCard)
            .cornerRadius(18)
            .shadow(color: Color.hhInk.opacity(0.06), radius: 10, x: 0, y: 3)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Account Row

struct AccountRow: View {
    let account: FinancialAccount

    var body: some View {
        HStack(spacing: 14) {
            Text(institutionInitial)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 42, height: 42)
                .background(institutionColor)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(account.accountName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.hhInk)
                Text("\(account.institutionName) · ••\(account.maskNumber ?? "••")")
                    .font(.system(size: 12))
                    .foregroundColor(.hhFaint)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(displayBalance, format: .currency(code: "CAD"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.hhInk)
                Text(accountTypeLabel)
                    .font(.system(size: 11))
                    .foregroundColor(.hhFaint)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color.hhFaint.opacity(0.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var institutionInitial: String { String(account.institutionName.prefix(1)) }

    private var institutionColor: Color {
        let name = account.institutionName.lowercased()
        if name.contains("td")        { return Color(red: 0.20, green: 0.51, blue: 0.22) }
        if name.contains("scotia")    { return Color(red: 0.85, green: 0.05, blue: 0.10) }
        if name.contains("rbc")       { return Color(red: 0.0,  green: 0.27, blue: 0.58) }
        if name.contains("bmo")       { return Color(red: 0.0,  green: 0.45, blue: 0.76) }
        if name.contains("cibc")      { return Color(red: 0.85, green: 0.50, blue: 0.0)  }
        return .hhAccent
    }

    private var displayBalance: Double {
        account.accountType == "credit" ? account.balance : (account.availableBalance ?? account.balance)
    }

    private var accountTypeLabel: String {
        switch account.accountType {
        case "checking": return "Chequing"
        case "savings":  return "Savings"
        case "credit":   return "Balance owing"
        default:         return account.accountType.capitalized
        }
    }
}

// MARK: - Detected Bill Row

struct DetectedBillRow: View {
    let bill: DetectedBill

    var body: some View {
        HStack(spacing: 14) {
            Text(bill.emoji)
                .font(.system(size: 20))
                .frame(width: 42, height: 42)
                .background(Circle().fill(rowColor.opacity(0.1)))

            VStack(alignment: .leading, spacing: 3) {
                Text(bill.merchantName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(bill.isPaidThisMonth ? .hhFaint : .hhInk)
                Text(dueLabel)
                    .font(.system(size: 12))
                    .foregroundColor(rowColor)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(bill.amount, format: .currency(code: "CAD"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(bill.isPaidThisMonth ? .hhFaint : .hhInk)
                if bill.isPaidThisMonth {
                    Text("Paid")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.hhGreen)
                } else if bill.isOverdue {
                    Text("Overdue")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.red)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.hhCard)
        .cornerRadius(14)
        .shadow(color: Color.hhInk.opacity(0.04), radius: 5, x: 0, y: 1)
    }

    private var rowColor: Color {
        if bill.isPaidThisMonth { return .hhGreen }
        if bill.isOverdue       { return .red }
        if bill.isDueSoon       { return .hhBlue }
        return .hhSub
    }

    private var dueLabel: String {
        if bill.isPaidThisMonth { return "Paid this month" }
        guard let days = bill.daysUntilDue else { return "Monthly" }
        if days < 0  { return "Overdue" }
        if days == 0 { return "Due today" }
        if days == 1 { return "Due tomorrow" }
        return "Due in \(days) days"
    }
}

// MARK: - Payable Bill Row  (Phase 4: shows Pay button when vopayPayments is enabled)

struct PayableBillRow: View {
    let bill: DetectedBill
    let isScheduled: Bool
    let onPay: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(bill.emoji)
                .font(.system(size: 20))
                .frame(width: 42, height: 42)
                .background(Circle().fill(rowColor.opacity(0.1)))

            VStack(alignment: .leading, spacing: 3) {
                Text(bill.merchantName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.hhInk)
                Text(dueLabel)
                    .font(.system(size: 12))
                    .foregroundColor(rowColor)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(bill.amount, format: .currency(code: "CAD"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.hhInk)
                if isScheduled {
                    Text("Scheduled")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.hhBlue)
                } else {
                    Button("Pay", action: onPay)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.hhAccent)
                        .cornerRadius(8)
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.hhCard)
        .cornerRadius(14)
        .shadow(color: Color.hhInk.opacity(0.04), radius: 5, x: 0, y: 1)
    }

    private var rowColor: Color {
        if bill.isOverdue { return .red }
        if bill.isDueSoon { return .hhBlue }
        return .hhSub
    }

    private var dueLabel: String {
        guard let days = bill.daysUntilDue else { return "Monthly" }
        if days < 0  { return "Overdue" }
        if days == 0 { return "Due today" }
        if days == 1 { return "Due tomorrow" }
        return "Due in \(days) days"
    }
}

// MARK: - Subscription Row

struct SubscriptionRow: View {
    let sub: DetectedSubscription

    var body: some View {
        HStack(spacing: 14) {
            Text(sub.emoji)
                .font(.system(size: 20))
                .frame(width: 42, height: 42)
                .background(Circle().fill(Color.hhShell))

            VStack(alignment: .leading, spacing: 2) {
                Text(sub.merchantName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.hhInk)
                if sub.hasIncreased, let inc = sub.increaseAmount {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 9, weight: .bold))
                        Text("Increased by \(inc, format: .currency(code: "CAD"))")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange)
                } else {
                    Text(sub.frequency.capitalized)
                        .font(.system(size: 12))
                        .foregroundColor(.hhFaint)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(sub.amount, format: .currency(code: "CAD"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.hhInk)
                Text("/ mo")
                    .font(.system(size: 10))
                    .foregroundColor(.hhFaint)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Transaction Row

struct TransactionRow: View {
    let txn: FDTransaction

    var body: some View {
        let cat = TxCategory.from(plaidCategory: txn.category, merchantName: txn.merchantName ?? txn.description)
        let isCredit = txn.amount < 0

        HStack(spacing: 12) {
            Image(systemName: cat.icon)
                .font(.system(size: 14))
                .foregroundColor(cat.color)
                .frame(width: 40, height: 40)
                .background(cat.color.opacity(0.1))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(txn.merchantName ?? txn.description)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.hhInk)
                    .lineLimit(1)
                Text(txn.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 11))
                    .foregroundColor(.hhFaint)
            }

            Spacer()

            Text(isCredit ? "+\(abs(txn.amount), format: .currency(code: "CAD"))" : "\(txn.amount, format: .currency(code: "CAD"))")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isCredit ? .hhGreen : .hhInk)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

// MARK: - Section Header  (shared across Money, Account, Subscription, You views)

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.hhInk)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(.hhFaint)
            }
            Spacer()
        }
    }
}

// MARK: - Bill Detection Sheet

struct BillDetectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(FinancialStore.self) private var store

    var body: some View {
        NavigationStack {
            ZStack {
                Color.hhBg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        Text("We found recurring payments in your transaction history. Confirm them to track automatically.")
                            .font(.system(size: 14))
                            .foregroundColor(.hhSub)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)

                        if store.pendingDetectionBills.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 48))
                                    .foregroundColor(.hhGreen)
                                    .padding(.top, 40)
                                Text("All caught up")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.hhInk)
                            }
                        } else {
                            VStack(spacing: 12) {
                                ForEach(store.pendingDetectionBills) { bill in
                                    DetectionBillCard(bill: bill)
                                        .environment(store)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        Spacer(minLength: 40)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Detected Bills")
            .hhNavTitleStyle(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.foregroundColor(.hhAccent)
                }
            }
        }
    }
}

// MARK: - Detection Bill Card

struct DetectionBillCard: View {
    @Environment(FinancialStore.self) private var store
    let bill: DetectedBill
    @State private var decided = false

    var body: some View {
        if !decided {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text(bill.emoji)
                        .font(.system(size: 22))
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Color.hhAccent.opacity(0.1)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(bill.merchantName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.hhInk)
                        Text("Usually around \(bill.amount, format: .currency(code: "CAD")) / \(bill.frequency)")
                            .font(.system(size: 13))
                            .foregroundColor(.hhSub)
                        if let next = bill.predictedNextDate {
                            Text("Next: \(next.formatted(date: .abbreviated, time: .omitted))")
                                .font(.system(size: 12))
                                .foregroundColor(.hhFaint)
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            store.dismissBill(id: bill.id)
                            decided = true
                        }
                    } label: {
                        Text("Not a bill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.hhSub)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.hhShell)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            store.confirmBill(id: bill.id)
                            decided = true
                        }
                    } label: {
                        Text("Add to Household OS")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.hhAccent)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .background(Color.hhCard)
            .cornerRadius(18)
            .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .scale(scale: 0.88).combined(with: .opacity)
            ))
        }
    }
}

// MARK: - Connect Accounts Sheet

struct ConnectAccountsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.hhBg.ignoresSafeArea()
                VStack(spacing: 28) {
                    VStack(spacing: 14) {
                        Image(systemName: "building.columns.fill")
                            .font(.system(size: 52))
                            .foregroundColor(.hhBlue)
                            .padding(.top, 36)
                        Text("Connect your bank")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.hhInk)
                        Text("Household OS uses Plaid to securely read your balances, bills, and transactions. Your credentials are never stored by us.")
                            .font(.system(size: 14))
                            .foregroundColor(.hhSub)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }

                    VStack(spacing: 12) {
                        featureRow("Automatic bill detection")
                        featureRow("Real-time balances")
                        featureRow("Safe to spend calculation")
                        featureRow("Cash-flow forecasting")
                    }
                    .padding(.horizontal, 24)

                    VStack(spacing: 10) {
                        Text("Connect Bank Account")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.hhFaint)
                            .cornerRadius(14)
                        Text("Bank-level 256-bit encryption · Read-only access")
                            .font(.system(size: 11))
                            .foregroundColor(.hhFaint)
                    }
                    .padding(.horizontal, 24)
                    Spacer()
                }
            }
            .navigationTitle("Connect Accounts")
            .hhNavTitleStyle(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.foregroundColor(.hhAccent)
                }
            }
        }
    }

    private func featureRow(_ label: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.hhGreen)
            Text(label).font(.system(size: 14, weight: .medium)).foregroundColor(.hhInk)
            Spacer()
        }
    }
}

#Preview {
    NavigationStack { MoneyView() }
        .environment(FinancialStore(provider: PlaidSandboxProvider()))
        .environment(PaymentStore())
        .environment(RewardsStore(provider: WildfireSandboxProvider()))
}
