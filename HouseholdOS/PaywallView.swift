import SwiftUI
import StoreKit

// MARK: - Paywall View

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(StoreKitStore.self) private var storeKitStore

    @State private var selectedPlan: PaywallPlan = .annual

    enum PaywallPlan { case monthly, annual }

    private let features: [(icon: String, title: String, detail: String)] = [
        ("bolt.circle.fill",      "Safe AutoPay",                  "Automated bill payments with multi-point safety checks"),
        ("building.columns.fill", "Unlimited linked accounts",     "Connect every bank, card, and loan"),
        ("chart.line.uptrend.xyaxis", "Advanced forecasting",      "30/60/90-day cash-flow predictions"),
        ("person.2.fill",         "Dual household approvals",      "Two-person sign-off for large payments"),
        ("exclamationmark.triangle.fill", "Anomaly detection",     "AI-powered unusual charge alerts"),
        ("slider.horizontal.3",   "Unlimited automation rules",    "Custom money rules with no limits"),
        ("wrench.and.screwdriver.fill", "Home intelligence",       "Predictive maintenance and seasonal planning"),
        ("sparkles",              "Savings analysis",              "See every dollar saved across categories"),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.hhBg.ignoresSafeArea()
                if storeKitStore.isPremium {
                    premiumActiveView
                } else {
                    purchaseView
                }
            }
            .navigationTitle("Household OS+")
            .hhNavTitleStyle(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.foregroundColor(.hhAccent)
                }
            }
        }
        .task { await storeKitStore.load() }
    }

    // MARK: - Purchase View

    private var purchaseView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 28) {
                // Hero
                VStack(spacing: 12) {
                    Image(systemName: "star.circle.fill")
                        .font(.system(size: 68))
                        .foregroundStyle(LinearGradient(colors: [.yellow, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .padding(.top, 28)
                    Text("Household OS+")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.hhInk)
                    Text("The full operating system for your household.\nEvery financial feature. Every automation.")
                        .font(.system(size: 15))
                        .foregroundColor(.hhSub)
                        .multilineTextAlignment(.center)
                }

                // Feature list
                VStack(spacing: 14) {
                    ForEach(features, id: \.title) { f in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: f.icon)
                                .font(.system(size: 16))
                                .foregroundColor(.hhGreen)
                                .frame(width: 24)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.hhInk)
                                Text(f.detail)
                                    .font(.system(size: 13))
                                    .foregroundColor(.hhSub)
                            }
                            Spacer()
                        }
                    }
                }

                // Plan picker
                planPicker

                // CTA
                ctaSection

                // Legal
                VStack(spacing: 6) {
                    Text("Payment will be charged to your Apple ID. Subscriptions renew automatically unless cancelled at least 24 hours before the end of the current period. Manage in App Store Settings.")
                        .font(.system(size: 10))
                        .foregroundColor(.hhFaint)
                        .multilineTextAlignment(.center)
                    if FeatureFlags.sandboxBannerVisible {
                        Text("Sandbox — activate HouseholdOSPlus.storekit in scheme (Edit Scheme → Run → Options → StoreKit Configuration) to enable purchases")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.hhAccent)
                            .multilineTextAlignment(.center)
                    }
                }

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Plan Picker

    private var planPicker: some View {
        HStack(spacing: 10) {
            planPill(
                plan: .monthly,
                label: "Monthly",
                price: storeKitStore.monthlyProduct?.displayPrice ?? "$4.99",
                period: "/ month",
                badge: nil
            )
            planPill(
                plan: .annual,
                label: "Annual",
                price: storeKitStore.annualProduct?.displayPrice ?? "$39.99",
                period: "/ year",
                badge: "SAVE 33%"
            )
        }
    }

    private func planPill(plan: PaywallPlan, label: String, price: String, period: String, badge: String?) -> some View {
        let isSelected = selectedPlan == plan
        return Button { withAnimation(.spring(response: 0.25)) { selectedPlan = plan } } label: {
            VStack(spacing: 5) {
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.hhGreen)
                        .cornerRadius(6)
                }
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isSelected ? .white : .hhSub)
                Text(price)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(isSelected ? .white : .hhInk)
                Text(period)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .white.opacity(0.75) : .hhFaint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(isSelected ? Color.hhAccent : Color.hhCard)
            .cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? Color.clear : Color.hhFaint.opacity(0.2), lineWidth: 1))
            .shadow(
                color: isSelected ? Color.hhAccent.opacity(0.3) : Color.hhInk.opacity(0.04),
                radius: isSelected ? 12 : 4, x: 0, y: 2
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - CTA

    private var ctaSection: some View {
        VStack(spacing: 12) {
            if let err = storeKitStore.purchaseError {
                Text(err)
                    .font(.system(size: 13))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                let product = selectedPlan == .monthly
                    ? storeKitStore.monthlyProduct
                    : storeKitStore.annualProduct
                guard let product else { return }
                Task { await storeKitStore.purchase(product) }
            } label: {
                Group {
                    if storeKitStore.isPurchasing {
                        ProgressView().progressViewStyle(.circular).tint(.white)
                    } else if storeKitStore.products.isEmpty {
                        Text("StoreKit Not Configured")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                    } else {
                        let priceStr = selectedPlan == .monthly
                            ? (storeKitStore.monthlyProduct?.displayPrice ?? "$4.99")
                            : (storeKitStore.annualProduct?.displayPrice ?? "$39.99")
                        let suffix = selectedPlan == .monthly ? "/mo" : "/yr"
                        Text("Subscribe · \(priceStr)\(suffix)")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(storeKitStore.products.isEmpty ? Color.hhFaint : Color.hhAccent)
                .cornerRadius(14)
            }
            .buttonStyle(.plain)
            .disabled(storeKitStore.isPurchasing || storeKitStore.products.isEmpty)

            Button {
                Task { await storeKitStore.restore() }
            } label: {
                if storeKitStore.isRestoring {
                    ProgressView().scaleEffect(0.8).tint(.hhAccent)
                } else {
                    Text("Restore Purchases")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.hhAccent)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Premium Active View

    private var premiumActiveView: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "star.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(LinearGradient(colors: [.yellow, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))

                VStack(spacing: 6) {
                    Text("You're on Household OS+")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.hhInk)
                    if let product = storeKitStore.activeProduct {
                        Text("\(product.displayName) · \(product.displayPrice)")
                            .font(.system(size: 15))
                            .foregroundColor(.hhSub)
                    }
                }
            }

            VStack(spacing: 0) {
                ForEach(features.prefix(4), id: \.title) { f in
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.hhGreen)
                            .font(.system(size: 16))
                        Text(f.title)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.hhInk)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 13)
                    if f.title != features.prefix(4).last?.title {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .background(Color.hhCard)
            .cornerRadius(18)
            .padding(.horizontal, 20)

            Button {
                if let url = URL(string: "itms-apps://apps.apple.com/account/subscriptions") {
                    openURL(url)
                }
            } label: {
                Text("Manage in App Store")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.hhAccent)
            }
            .buttonStyle(.plain)

            Spacer()

            Button { dismiss() } label: {
                Text("Done")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.hhAccent)
                    .cornerRadius(14)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
    }
}

#Preview {
    PaywallView()
        .environment(StoreKitStore())
}
