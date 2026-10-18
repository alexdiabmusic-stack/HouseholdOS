import SwiftUI

// MARK: - Rewards View (Phase 7: Wildfire / Fidel card-linked rewards)

struct RewardsView: View {
    @Environment(RewardsStore.self) private var store
    @State private var selectedCategory: String = "all"

    private static let allCategories = ["all", "food", "grocery", "home", "health", "tech", "fashion", "sports", "pets", "auto"]

    private var filteredOffers: [RewardOffer] {
        guard selectedCategory != "all" else { return store.offers }
        return store.offers.filter { $0.category == selectedCategory }
    }

    var body: some View {
        ZStack {
            Color.hhBg.ignoresSafeArea()
            if store.isLoadingOffers && store.offers.isEmpty {
                loadingState
            } else {
                mainContent
            }
        }
        .navigationTitle("Household Rewards")
        .hhNavTitleStyle(.large)
        .task { await store.load() }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                balanceCard
                howItWorksRow
                categoryFilter
                if store.isLoadingOffers {
                    ProgressView().tint(.hhAccent).padding(.top, 8)
                } else if filteredOffers.isEmpty {
                    emptyOffers
                } else {
                    offersSection
                }
                Spacer(minLength: 80)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }

    // MARK: - Balance Card

    private var balanceCard: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "sparkle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                Text("HOUSEHOLD REWARDS")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.8))
                    .tracking(1.2)
                Spacer()
                Text("Card-Linked")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.2))
                    .cornerRadius(8)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Balance
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(store.balance.confirmed, format: .currency(code: "CAD").precision(.fractionLength(2)))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("earned")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.bottom, 4)
            }
            .padding(.horizontal, 20)

            // Sub-row
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pending")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                    Text(store.balance.pending, format: .currency(code: "CAD").precision(.fractionLength(2)))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                }
                Rectangle()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 1, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lifetime")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                    Text(store.balance.lifetime, format: .currency(code: "CAD").precision(.fractionLength(2)))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
        .background(
            LinearGradient(
                colors: [Color.hhGreen, Color.hhGreen.opacity(0.75)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .cornerRadius(20)
        .shadow(color: Color.hhGreen.opacity(0.35), radius: 12, x: 0, y: 6)
    }

    // MARK: - How It Works

    private var howItWorksRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "creditcard.and.123")
                .font(.system(size: 20))
                .foregroundColor(.hhAccent)
                .frame(width: 42, height: 42)
                .background(Color.hhAccent.opacity(0.1))
                .cornerRadius(10)
            VStack(alignment: .leading, spacing: 2) {
                Text("Earns automatically")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.hhInk)
                Text("Pay with your linked card at any participating merchant and cashback is applied automatically.")
                    .font(.system(size: 12))
                    .foregroundColor(.hhSub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.hhCard)
        .cornerRadius(14)
        .shadow(color: Color.hhInk.opacity(0.04), radius: 6, x: 0, y: 2)
    }

    // MARK: - Category Filter

    private var categoryFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.allCategories, id: \.self) { cat in
                    let count = cat == "all"
                        ? store.offers.count
                        : store.offers.filter { $0.category == cat }.count
                    if count > 0 || cat == "all" {
                        RewardsCategoryChip(
                            label: cat == "all" ? "All (\(store.offers.count))" : cat.capitalized,
                            isSelected: selectedCategory == cat
                        ) {
                            selectedCategory = cat
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Offers Section

    private var offersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Active Offers",
                          subtitle: "\(filteredOffers.count) merchant\(filteredOffers.count == 1 ? "" : "s")")

            VStack(spacing: 0) {
                ForEach(Array(filteredOffers.enumerated()), id: \.element.id) { index, offer in
                    OfferRow(offer: offer)
                    if index < filteredOffers.count - 1 {
                        Divider().padding(.leading, 66)
                    }
                }
            }
            .background(Color.hhCard)
            .cornerRadius(18)
            .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
        }
    }

    // MARK: - Empty State

    private var emptyOffers: some View {
        VStack(spacing: 12) {
            Image(systemName: "tag.slash")
                .font(.system(size: 36))
                .foregroundColor(.hhFaint)
            Text("No offers in this category")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.hhSub)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.3).tint(.hhAccent)
            Text("Loading rewards…")
                .font(.system(size: 14))
                .foregroundColor(.hhFaint)
        }
    }
}

// MARK: - Offer Row

private struct OfferRow: View {
    let offer: RewardOffer
    private let expiringSoonThreshold: TimeInterval = 30 * 24 * 60 * 60 // 30 days

    private var isExpiringSoon: Bool {
        guard let expiry = offer.expiryDate else { return false }
        return expiry.timeIntervalSinceNow < expiringSoonThreshold
    }

    private var daysUntilExpiry: Int? {
        guard let expiry = offer.expiryDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expiry).day
    }

    var body: some View {
        HStack(spacing: 14) {
            // Merchant initial avatar
            Text(String(offer.merchantName.prefix(1)).uppercased())
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 42, height: 42)
                .background(offerColor(for: offer.category))
                .cornerRadius(12)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(offer.merchantName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.hhInk)
                    if isExpiringSoon, let days = daysUntilExpiry {
                        Text("\(days)d left")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(4)
                    }
                }
                Text(offer.description)
                    .font(.system(size: 12))
                    .foregroundColor(.hhSub)
            }

            Spacer()

            // Reward percent badge
            VStack(spacing: 1) {
                Text(String(format: "%.0f%%", offer.rewardPercent))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.hhGreen)
                Text("back")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.hhGreen.opacity(0.8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Category Chip

private struct RewardsCategoryChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isSelected ? .white : .hhSub)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? Color.hhAccent : Color.hhCard)
                .cornerRadius(20)
                .shadow(color: Color.hhInk.opacity(isSelected ? 0.12 : 0.04), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Color Helper

private func offerColor(for category: String) -> Color {
    switch category {
    case "food":    return Color(red: 0.96, green: 0.49, blue: 0.31)
    case "grocery": return Color(red: 0.38, green: 0.73, blue: 0.40)
    case "home":    return Color(red: 0.47, green: 0.56, blue: 0.78)
    case "health":  return Color(red: 0.90, green: 0.45, blue: 0.55)
    case "tech":    return Color(red: 0.42, green: 0.68, blue: 0.90)
    case "fashion": return Color(red: 0.75, green: 0.52, blue: 0.82)
    case "sports":  return Color(red: 0.28, green: 0.72, blue: 0.64)
    case "pets":    return Color(red: 0.88, green: 0.65, blue: 0.35)
    case "auto":    return Color(red: 0.55, green: 0.55, blue: 0.60)
    default:        return Color.hhAccent
    }
}

#Preview {
    NavigationStack { RewardsView() }
        .environment(RewardsStore(provider: WildfireSandboxProvider()))
}
