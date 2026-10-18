import SwiftUI

// MARK: - Bill Pay Sheet

struct BillPaySheet: View {
    @Environment(FinancialStore.self) private var financialStore
    @Environment(PaymentStore.self) private var paymentStore
    @Environment(\.dismiss) private var dismiss
    let bill: DetectedBill

    @State private var scheduledDate: Date
    @State private var isScheduling = false
    @State private var scheduledPayment: ScheduledPayment?
    @State private var errorMessage: String?

    init(bill: DetectedBill) {
        self.bill = bill
        let due = bill.predictedNextDate ?? Date()
        let threeBefore = Calendar.current.date(byAdding: .day, value: -3, to: due) ?? due
        let today = Calendar.current.startOfDay(for: Date())
        _scheduledDate = State(initialValue: max(threeBefore, today))
    }

    private var postPaymentSafe: Double {
        max(0, financialStore.safeToSpend - bill.amount)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.hhBg.ignoresSafeArea()
                if let payment = scheduledPayment {
                    successView(payment: payment)
                } else {
                    scheduleForm
                }
            }
            .navigationTitle("Pay \(bill.merchantName)")
            .hhNavTitleStyle(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.hhAccent)
                }
            }
        }
    }

    // MARK: - Form

    private var scheduleForm: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                // Bill summary
                VStack(spacing: 12) {
                    HStack(spacing: 14) {
                        Text(bill.emoji)
                            .font(.system(size: 24))
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(Color.hhShell))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(bill.merchantName)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.hhInk)
                            Text(bill.frequency.capitalized)
                                .font(.system(size: 12))
                                .foregroundColor(.hhFaint)
                        }
                        Spacer()
                        Text(bill.amount, format: .currency(code: "CAD"))
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.hhInk)
                    }
                    if let due = bill.predictedNextDate {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar")
                                .font(.system(size: 11))
                                .foregroundColor(.hhFaint)
                            Text("Due \(due.formatted(date: .long, time: .omitted))")
                                .font(.system(size: 13))
                                .foregroundColor(.hhSub)
                            Spacer()
                        }
                    }
                }
                .padding(16)
                .background(Color.hhCard)
                .cornerRadius(16)

                // Date picker
                VStack(alignment: .leading, spacing: 10) {
                    Text("SEND PAYMENT ON")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.hhFaint)
                    DatePicker(
                        "Payment date",
                        selection: $scheduledDate,
                        in: Calendar.current.startOfDay(for: Date())...,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .tint(.hhAccent)
                    .background(Color.hhCard)
                    .cornerRadius(16)
                }

                // Impact preview
                VStack(spacing: 10) {
                    Text("FINANCIAL IMPACT")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.hhFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Safe to spend now")
                                .font(.system(size: 12))
                                .foregroundColor(.hhSub)
                            Text(financialStore.safeToSpend, format: .currency(code: "CAD"))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.hhInk)
                        }
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12))
                            .foregroundColor(.hhFaint)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("After payment")
                                .font(.system(size: 12))
                                .foregroundColor(.hhSub)
                            Text(postPaymentSafe, format: .currency(code: "CAD"))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(postPaymentSafe < 500 ? .orange : .hhGreen)
                        }
                    }
                    .padding(16)
                    .background(Color.hhCard)
                    .cornerRadius(14)
                }

                if FeatureFlags.sandboxBannerVisible {
                    HStack(spacing: 8) {
                        Image(systemName: "flask.fill").font(.system(size: 11))
                        Text("Sandbox — no real money will be moved")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(.hhAccent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.hhAccent.opacity(0.08))
                    .cornerRadius(10)
                }

                if let err = errorMessage {
                    Text(err)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.red.opacity(0.08))
                        .cornerRadius(10)
                }

                Button {
                    Task { await schedulePayment() }
                } label: {
                    HStack(spacing: 10) {
                        if isScheduling { ProgressView().tint(.white) }
                        Text(isScheduling ? "Scheduling…" : "Schedule Payment")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(isScheduling ? Color.hhFaint : Color.hhAccent)
                    .cornerRadius(14)
                }
                .disabled(isScheduling)

                Text("EFT payments take 1–3 business days to clear. The bill is only marked paid after your bank confirms the transfer.")
                    .font(.system(size: 11))
                    .foregroundColor(.hhFaint)
                    .multilineTextAlignment(.center)

                Spacer(minLength: 40)
            }
            .padding(20)
        }
    }

    // MARK: - Success

    private func successView(payment: ScheduledPayment) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.hhGreen)
            VStack(spacing: 8) {
                Text("Payment Scheduled")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.hhInk)
                Text("\(bill.amount.formatted(.currency(code: "CAD"))) to \(bill.merchantName) on \(scheduledDate.formatted(date: .long, time: .omitted)).")
                    .font(.system(size: 14))
                    .foregroundColor(.hhSub)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            Button("Done") { dismiss() }
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.hhAccent)
                .cornerRadius(14)
                .padding(.horizontal, 20)
            Spacer()
        }
    }

    private func schedulePayment() async {
        isScheduling = true
        errorMessage = nil
        do {
            scheduledPayment = try await paymentStore.scheduleManualPayment(
                bill: bill, on: scheduledDate, financialStore: financialStore
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isScheduling = false
    }
}

// MARK: - Safe AutoPay Settings View

struct SafeAutoPaySettingsView: View {
    @Environment(FinancialStore.self) private var financialStore
    @Environment(PaymentStore.self) private var paymentStore
    @Environment(\.dismiss) private var dismiss

    @State private var showingRuleSheet: DetectedBill?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.hhBg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        killSwitchCard
                        if paymentStore.safeAutoPayEnabled {
                            billRulesSection
                        } else {
                            howItWorksSection
                        }
                        Spacer(minLength: 60)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Safe AutoPay")
            .hhNavTitleStyle(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.foregroundColor(.hhAccent)
                }
            }
            .sheet(item: $showingRuleSheet) { bill in
                AutoPayRuleSheet(bill: bill)
                    .environment(financialStore)
                    .environment(paymentStore)
            }
        }
    }

    // MARK: - Kill Switch

    private var killSwitchCard: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Safe AutoPay")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.hhInk)
                    Text(paymentStore.safeAutoPayEnabled
                         ? "Bills are paid automatically when funds are available"
                         : "Automatically pay confirmed bills before they're due")
                        .font(.system(size: 13))
                        .foregroundColor(.hhSub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(
                    get: { paymentStore.safeAutoPayEnabled },
                    set: { paymentStore.toggleSafeAutoPay($0) }
                ))
                .labelsHidden()
                .tint(.hhGreen)
            }
            if FeatureFlags.sandboxBannerVisible {
                HStack(spacing: 6) {
                    Image(systemName: "flask.fill").font(.system(size: 10))
                    Text("Sandbox — no real payments will be made")
                        .font(.system(size: 11))
                }
                .foregroundColor(.hhAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(Color.hhCard)
        .cornerRadius(16)
        .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    // MARK: - Bill Rules

    private var billRulesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BILLS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.hhFaint)

            if financialStore.confirmedBills.isEmpty {
                Text("Confirm bills in the Money tab first to enable AutoPay for them.")
                    .font(.system(size: 13))
                    .foregroundColor(.hhSub)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.hhCard)
                    .cornerRadius(14)
            } else {
                VStack(spacing: 0) {
                    ForEach(financialStore.confirmedBills) { bill in
                        AutoPayBillRow(bill: bill, rule: paymentStore.rule(forBillID: bill.id)) {
                            showingRuleSheet = bill
                        }
                        if bill.id != financialStore.confirmedBills.last?.id {
                            Divider().padding(.leading, 64)
                        }
                    }
                }
                .background(Color.hhCard)
                .cornerRadius(16)
                .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
            }
        }
    }

    // MARK: - How it works

    private var howItWorksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HOW IT WORKS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.hhFaint)
            VStack(spacing: 0) {
                ForEach(howItWorksItems, id: \.title) { item in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: item.icon)
                            .font(.system(size: 14))
                            .foregroundColor(.hhAccent)
                            .frame(width: 30, height: 30)
                            .background(Color.hhAccent.opacity(0.1))
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.hhInk)
                            Text(item.body)
                                .font(.system(size: 12))
                                .foregroundColor(.hhSub)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    if item.title != howItWorksItems.last?.title {
                        Divider().padding(.leading, 60)
                    }
                }
            }
            .background(Color.hhCard)
            .cornerRadius(16)
            .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
        }
    }

    private struct HowItWorksItem {
        let icon: String
        let title: String
        let body: String
    }

    private let howItWorksItems: [HowItWorksItem] = [
        .init(icon: "checkmark.shield",        title: "You stay in control",     body: "You set per-bill rules — max amount and how many days before the due date."),
        .init(icon: "dollarsign.circle",        title: "Funds check first",       body: "AutoPay only fires when your safe-to-spend covers the bill plus a safety buffer."),
        .init(icon: "bell.badge",               title: "Notified in advance",     body: "Upcoming auto-payments appear in your Payment History before they process."),
        .init(icon: "arrow.counterclockwise",   title: "Always cancellable",      body: "Cancel any scheduled payment before it enters processing."),
    ]
}

// MARK: - AutoPay Bill Row

struct AutoPayBillRow: View {
    let bill: DetectedBill
    let rule: AutoPayRule?
    let onConfigure: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(bill.emoji)
                .font(.system(size: 20))
                .frame(width: 42, height: 42)
                .background(Circle().fill(Color.hhShell))
            VStack(alignment: .leading, spacing: 3) {
                Text(bill.merchantName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.hhInk)
                Text(ruleLabel)
                    .font(.system(size: 12))
                    .foregroundColor(rule?.isEnabled == true ? .hhGreen : .hhFaint)
            }
            Spacer()
            Button("Configure", action: onConfigure)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.hhAccent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var ruleLabel: String {
        guard let rule, rule.isEnabled else { return "AutoPay off" }
        return "AutoPay · \(rule.daysBefore)d before due · max \(rule.maxAmount.formatted(.currency(code: "CAD")))"
    }
}

// MARK: - AutoPay Rule Sheet

struct AutoPayRuleSheet: View {
    @Environment(PaymentStore.self) private var paymentStore
    @Environment(\.dismiss) private var dismiss
    let bill: DetectedBill

    @State private var isEnabled  = false
    @State private var daysBefore = 3
    @State private var maxAmount  = 0.0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.hhBg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        // Bill header
                        HStack(spacing: 12) {
                            Text(bill.emoji).font(.system(size: 28))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bill.merchantName)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.hhInk)
                                Text("\(bill.amount.formatted(.currency(code: "CAD"))) / \(bill.frequency)")
                                    .font(.system(size: 13))
                                    .foregroundColor(.hhSub)
                            }
                            Spacer()
                        }
                        .padding(16)
                        .background(Color.hhCard)
                        .cornerRadius(14)

                        // Enable toggle
                        HStack {
                            Text("Enable AutoPay for this bill")
                                .font(.system(size: 15))
                                .foregroundColor(.hhInk)
                            Spacer()
                            Toggle("", isOn: $isEnabled).tint(.hhGreen).labelsHidden()
                        }
                        .padding(16)
                        .background(Color.hhCard)
                        .cornerRadius(14)

                        if isEnabled {
                            // Days before
                            VStack(alignment: .leading, spacing: 10) {
                                Text("PAY HOW MANY DAYS BEFORE DUE")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.hhFaint)
                                HStack(spacing: 8) {
                                    ForEach([1, 2, 3, 5, 7], id: \.self) { d in
                                        Button {
                                            daysBefore = d
                                        } label: {
                                            Text("\(d)d")
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundColor(daysBefore == d ? .white : .hhSub)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 10)
                                                .background(daysBefore == d ? Color.hhAccent : Color.hhCard)
                                                .cornerRadius(10)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }

                            // Max amount cap
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("MAXIMUM AMOUNT")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.hhFaint)
                                    Spacer()
                                    Text(maxAmount.formatted(.currency(code: "CAD")))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.hhAccent)
                                }
                                Slider(value: $maxAmount, in: bill.amount...(bill.amount * 2), step: 5)
                                    .tint(.hhAccent)
                                Text("AutoPay won't fire if the actual charge exceeds this cap.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.hhFaint)
                            }
                        }

                        Spacer(minLength: 20)

                        Button { saveRule() } label: {
                            Text("Save Rule")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(Color.hhAccent)
                                .cornerRadius(14)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("AutoPay Rule")
            .hhNavTitleStyle(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.hhAccent)
                }
            }
            .onAppear { loadExistingRule() }
        }
    }

    private func loadExistingRule() {
        maxAmount = bill.amount * 1.1
        if let rule = paymentStore.rule(forBillID: bill.id) {
            isEnabled  = rule.isEnabled
            daysBefore = rule.daysBefore
            maxAmount  = rule.maxAmount
        }
    }

    private func saveRule() {
        paymentStore.setRule(forBillID: bill.id, daysBefore: daysBefore, maxAmount: maxAmount, enabled: isEnabled)
        dismiss()
    }
}

// MARK: - Payment History View

struct PaymentHistoryView: View {
    @Environment(PaymentStore.self) private var paymentStore

    var body: some View {
        ZStack {
            Color.hhBg.ignoresSafeArea()
            if paymentStore.allPayments.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(paymentStore.allPayments) { payment in
                            PaymentHistoryRow(payment: payment)
                        }
                        Spacer(minLength: 60)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
            }
        }
        .navigationTitle("Payment History")
        .hhNavTitleStyle(.inline)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundColor(.hhFaint)
            Text("No payments yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.hhInk)
            Text("Scheduled and past payments will appear here.")
                .font(.system(size: 14))
                .foregroundColor(.hhFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }
}

// MARK: - Payment History Row

struct PaymentHistoryRow: View {
    let payment: ScheduledPayment

    var body: some View {
        HStack(spacing: 14) {
            Text(payment.billEmoji)
                .font(.system(size: 20))
                .frame(width: 42, height: 42)
                .background(Circle().fill(statusColor.opacity(0.1)))

            VStack(alignment: .leading, spacing: 3) {
                Text(payment.billName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.hhInk)
                Text(payment.scheduledDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 12))
                    .foregroundColor(.hhFaint)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(payment.amount, format: .currency(code: "CAD"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.hhInk)
                Text(payment.status.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(statusColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.hhCard)
        .cornerRadius(14)
        .shadow(color: Color.hhInk.opacity(0.04), radius: 5, x: 0, y: 1)
    }

    private var statusColor: Color {
        switch payment.status {
        case .completed:  return .hhGreen
        case .failed:     return .red
        case .cancelled:  return .hhFaint
        case .scheduled:  return .hhBlue
        case .processing: return .orange
        }
    }
}
