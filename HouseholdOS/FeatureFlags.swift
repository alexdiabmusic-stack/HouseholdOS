import Foundation

// MARK: - Feature Flags
// Legacy prototype screens are retained only for data migration and previews.
// The shared app checks live backend capabilities; do not enable mock commerce in releases.
// All legacy Phase 2+ integrations are gated here.
// Flip a flag to true only after the corresponding provider is fully wired, tested in sandbox,
// and approved for production use. No flag should ever be set true client-side in production
// before the backend integration is complete.

enum FeatureFlags {
    // Phase 2: Financial intelligence  ✅ sandbox enabled
    static let financialConnections    = false   // Plaid account linking (sandbox)
    static let safeAutopay             = false  // Safe AutoPay engine (Phase 4)
    static let cashFlowForecasting     = false   // Cash-flow engine (sandbox)

    // Phase 4: Payments  ✅ sandbox enabled
    static let vopayPayments           = false   // VoPay bill pay / EFT (sandbox)
    static let billPay                 = false   // Biller search + payment (sandbox)
    static let rentPayments            = false  // Landlord rent automation
    static let creditCardAutomation    = false  // Credit card statement payments

    // Phase 3: Grocery commerce  ✅ sandbox enabled
    static let instacartCommerce       = false   // Instacart shopping integration (sandbox)

    // Phase 5: Services marketplace  ✅ sandbox enabled
    static let serviceMarketplace      = false   // Home services booking (sandbox)
    static let stripeConnect           = false   // Provider payouts via Stripe (sandbox)

    // Phase 8: Intelligence  ✅ sandbox enabled
    static let spendingInsights      = false   // Smart Insights dashboard
    static let anomalyDetection      = false   // Unusual charge / duplicate detection

    // Phase 7: Rewards  ✅ sandbox enabled
    static let cashback                = false   // Cashback provider (Wildfire / Fidel)
    static let cardLinkedOffers        = false   // Card-linked offer feed
    static let householdRewards        = false   // Household Rewards balance

    // Phase 6: Premium  ✅ StoreKit 2 enabled
    static let premiumSubscription     = false   // Household OS+ (StoreKit 2)

    // Developer / sandbox
    static let sandboxBannerVisible    = true   // Shows "Sandbox" indicator in debug builds
}
