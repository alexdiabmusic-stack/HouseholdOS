import Foundation

// MARK: - Feature Flags
// All Phase 2+ integrations are gated here.
// Flip a flag to true only after the corresponding provider is fully wired, tested in sandbox,
// and approved for production use. No flag should ever be set true client-side in production
// before the backend integration is complete.

enum FeatureFlags {
    // Phase 2: Financial intelligence  ✅ sandbox enabled
    static let financialConnections    = true   // Plaid account linking (sandbox)
    static let safeAutopay             = false  // Safe AutoPay engine (Phase 4)
    static let cashFlowForecasting     = true   // Cash-flow engine (sandbox)

    // Phase 4: Payments  ✅ sandbox enabled
    static let vopayPayments           = true   // VoPay bill pay / EFT (sandbox)
    static let billPay                 = true   // Biller search + payment (sandbox)
    static let rentPayments            = false  // Landlord rent automation
    static let creditCardAutomation    = false  // Credit card statement payments

    // Phase 3: Grocery commerce  ✅ sandbox enabled
    static let instacartCommerce       = true   // Instacart shopping integration (sandbox)

    // Phase 5: Services marketplace  ✅ sandbox enabled
    static let serviceMarketplace      = true   // Home services booking (sandbox)
    static let stripeConnect           = true   // Provider payouts via Stripe (sandbox)

    // Phase 8: Intelligence  ✅ sandbox enabled
    static let spendingInsights      = true   // Smart Insights dashboard
    static let anomalyDetection      = true   // Unusual charge / duplicate detection

    // Phase 7: Rewards  ✅ sandbox enabled
    static let cashback                = true   // Cashback provider (Wildfire / Fidel)
    static let cardLinkedOffers        = true   // Card-linked offer feed
    static let householdRewards        = true   // Household Rewards balance

    // Phase 6: Premium  ✅ StoreKit 2 enabled
    static let premiumSubscription     = true   // Household OS+ (StoreKit 2)

    // Developer / sandbox
    static let sandboxBannerVisible    = true   // Shows "Sandbox" indicator in debug builds
}
