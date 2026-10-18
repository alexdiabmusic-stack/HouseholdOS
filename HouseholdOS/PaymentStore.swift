import Foundation

// MARK: - Payment Domain Models

enum ScheduledPaymentStatus: String, Codable, CaseIterable {
    case scheduled    // queued, not yet sent to provider
    case processing   // sent to VoPay, awaiting server confirmation
    case completed    // confirmed paid (webhook received server-side in production)
    case failed       // VoPay returned an error
    case cancelled    // user cancelled before processing began

    var label: String {
        switch self {
        case .scheduled:  return "Scheduled"
        case .processing: return "Processing"
        case .completed:  return "Paid"
        case .failed:     return "Failed"
        case .cancelled:  return "Cancelled"
        }
    }

    var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
}

struct ScheduledPayment: Identifiable, Codable {
    let id: String               // VoPay payment reference returned by server
    let billID: String
    let billName: String
    let billEmoji: String
    let amount: Double
    let scheduledDate: Date
    var status: ScheduledPaymentStatus
    let idempotencyKey: String
    let createdAt: Date
    let isAutoScheduled: Bool
    var failureReason: String?
}

struct AutoPayRule: Identifiable, Codable {
    var id: String               // matches DetectedBill.id
    var isEnabled: Bool
    var daysBefore: Int          // schedule EFT N days before predictedNextDate (1–7)
    var maxAmount: Double        // safety cap — AutoPay won't fire if amount exceeds this
}

// MARK: - Payment Store

@Observable
@MainActor
final class PaymentStore {
    private(set) var pendingPayments: [ScheduledPayment] = []
    private(set) var paymentHistory:  [ScheduledPayment] = []
    private(set) var autoPayRules:    [AutoPayRule]      = []
    var safeAutoPayEnabled = false

    private let provider: any PaymentProvider

    private let pendingKey        = "hh.pendingPayments"
    private let historyKey        = "hh.paymentHistory"
    private let rulesKey          = "hh.autoPayRules"
    private let autoPayEnabledKey = "hh.safeAutoPayEnabled"

    init(provider: any PaymentProvider) { self.provider = provider }
    convenience init() { self.init(provider: ProviderRegistry.payment) }

    func load() {
        safeAutoPayEnabled = UserDefaults.standard.bool(forKey: autoPayEnabledKey)
        pendingPayments = decoded(from: pendingKey) ?? []
        paymentHistory  = decoded(from: historyKey) ?? []
        autoPayRules    = decoded(from: rulesKey)   ?? []
    }

    // MARK: - Manual Payment

    // Client-side safety check only — real enforcement happens server-side.
    // If safeToSpend minus the bill amount would drop below -$500, refuse early
    // so the user gets immediate feedback rather than a server-side rejection.
    func scheduleManualPayment(
        bill: DetectedBill,
        on date: Date,
        financialStore: FinancialStore
    ) async throws -> ScheduledPayment {
        guard financialStore.safeToSpend - bill.amount > -500 else {
            throw PaymentStoreError.insufficientFunds
        }
        guard !hasScheduledPayment(forBillID: bill.id) else {
            throw PaymentStoreError.alreadyScheduled
        }

        let idempotencyKey = "manual-\(bill.id)-\(Int(date.timeIntervalSince1970))"
        let request = PaymentRequest(
            amount: bill.amount,
            recipientID: bill.id,
            memo: bill.merchantName,
            scheduleDate: date,
            idempotencyKey: idempotencyKey
        )

        let response = try await provider.schedulePayment(request)

        let payment = ScheduledPayment(
            id: response.id,
            billID: bill.id,
            billName: bill.merchantName,
            billEmoji: bill.emoji,
            amount: bill.amount,
            scheduledDate: date,
            status: .scheduled,
            idempotencyKey: idempotencyKey,
            createdAt: Date(),
            isAutoScheduled: false
        )

        pendingPayments.insert(payment, at: 0)
        persist()
        return payment
    }

    // MARK: - Cancel

    func cancelPayment(_ payment: ScheduledPayment) async throws {
        guard payment.status == .scheduled else { return }
        try await provider.cancelPayment(id: payment.id)
        updateStatus(paymentID: payment.id, to: .cancelled)
    }

    // MARK: - Status Refresh

    func refreshStatuses() async {
        let active = pendingPayments.filter { !$0.status.isTerminal }
        for payment in active {
            guard let status = try? await provider.fetchStatus(paymentID: payment.id) else { continue }
            let mapped: ScheduledPaymentStatus
            switch status {
            case .completed:  mapped = .completed
            case .failed:     mapped = .failed
            case .cancelled:  mapped = .cancelled
            case .processing: mapped = .processing
            default:          mapped = .scheduled
            }
            updateStatus(paymentID: payment.id, to: mapped)
        }
    }

    // MARK: - AutoPay Rules

    func rule(forBillID id: String) -> AutoPayRule? {
        autoPayRules.first { $0.id == id }
    }

    func setRule(forBillID id: String, daysBefore: Int, maxAmount: Double, enabled: Bool) {
        if let idx = autoPayRules.firstIndex(where: { $0.id == id }) {
            autoPayRules[idx].isEnabled  = enabled
            autoPayRules[idx].daysBefore = daysBefore
            autoPayRules[idx].maxAmount  = maxAmount
        } else {
            autoPayRules.append(AutoPayRule(id: id, isEnabled: enabled,
                                            daysBefore: daysBefore, maxAmount: maxAmount))
        }
        persist()
    }

    func toggleSafeAutoPay(_ enabled: Bool) {
        safeAutoPayEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: autoPayEnabledKey)
    }

    // MARK: - Computed

    var allPayments: [ScheduledPayment] {
        (pendingPayments + paymentHistory).sorted { $0.createdAt > $1.createdAt }
    }

    func hasScheduledPayment(forBillID id: String) -> Bool {
        pendingPayments.contains { $0.billID == id && $0.status == .scheduled }
    }

    var enabledAutoPayRulesCount: Int {
        autoPayRules.filter { $0.isEnabled }.count
    }

    // MARK: - Persistence

    private func updateStatus(paymentID: String, to status: ScheduledPaymentStatus) {
        if let idx = pendingPayments.firstIndex(where: { $0.id == paymentID }) {
            pendingPayments[idx].status = status
            if status.isTerminal {
                let moved = pendingPayments.remove(at: idx)
                paymentHistory.insert(moved, at: 0)
            }
        }
        persist()
    }

    private func persist() {
        encode(pendingPayments, to: pendingKey)
        encode(paymentHistory,  to: historyKey)
        encode(autoPayRules,    to: rulesKey)
    }

    private func decoded<T: Decodable>(from key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T, to key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - Errors

enum PaymentStoreError: Error, LocalizedError {
    case insufficientFunds
    case alreadyScheduled
    case paymentNotFound

    var errorDescription: String? {
        switch self {
        case .insufficientFunds: return "Safe-to-spend balance is too low for this payment."
        case .alreadyScheduled:  return "A payment for this bill is already scheduled."
        case .paymentNotFound:   return "Payment not found."
        }
    }
}
