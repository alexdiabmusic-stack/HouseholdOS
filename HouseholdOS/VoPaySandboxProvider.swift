import Foundation

// Sandbox implementation of PaymentProvider (Phase 4: VoPay EFT).
// In production this is replaced by a server-side VoPay proxy that:
//   1. Validates the payment request against account rules, limits, and available balance
//   2. Initiates the EFT via VoPay's API entirely server-side
//   3. Returns the payment reference ID to the client for status polling
//   4. Marks a bill paid only after the VoPay confirmation webhook arrives server-side
// VoPay API credentials must never appear in the client bundle.
// No payment is ever initiated from client-side code in production.

struct VoPaySandboxProvider: PaymentProvider {
    let name = "VoPay (Sandbox)"

    func schedulePayment(_ request: PaymentRequest) async throws -> PaymentResponse {
        // Simulate VoPay EFT scheduling API call
        try await Task.sleep(nanoseconds: 1_200_000_000)

        guard request.amount > 0 else { throw ProviderError.notEnabled }

        let paymentID = "vopay-sandbox-\(UUID().uuidString.prefix(8).lowercased())"
        return PaymentResponse(
            id: paymentID,
            status: .pending,
            scheduledDate: request.scheduleDate
        )
    }

    func cancelPayment(id: String) async throws {
        // Simulate VoPay cancellation call
        try await Task.sleep(nanoseconds: 700_000_000)
        // Sandbox: always succeeds (real: VoPay rejects once processing begins)
    }

    func fetchStatus(paymentID: String) async throws -> PaymentStatus {
        // Simulate polling VoPay for status
        try await Task.sleep(nanoseconds: 400_000_000)
        // Sandbox: all payments eventually complete. Real status arrives via server webhook.
        return .completed
    }
}
