import SwiftUI

// MARK: - Subscription Manager View

struct SubscriptionManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(FinancialStore.self) private var store

    @State private var showDismissed = false

    private var dismissedSubs: [DetectedSubscription] {
        store.subscriptions.filter { store.dismissedSubIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.hhBg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        costSummaryCard
                        activeSubscriptionsSection
                        if !dismissedSubs.isEmpty {
                            dismissedSection
                        }
                        savingsOpportunitySection
                        Spacer(minLength: 60)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
            }
            .navigationTitle("Subscriptions")
            .hhNavTitleStyle(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.foregroundColor(.hhAccent)
                }
            }
        }
    }

    // MARK: - Cost Summary

    private var costSummaryCard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Total subscriptions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.hhSub)
                Text(store.totalSubscriptionCostMonthly, format: .currency(code: "CAD"))
                    .font(.system(size: 42, weight: .bold))
                    .foregroundColor(.hhInk)
                Text("per month")
                    .font(.system(size: 12))
                    .foregroundColor(.hhFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider().padding(.horizontal, 20)

            HStack(spacing: 0) {
                statCell(
                    label: "Per year",
                    value: (store.totalSubscriptionCostMonthly * 12).formatted(.currency(code: "CAD"))
                )
                Divider().frame(height: 32)
                statCell(
                    label: "Active",
                    value: "\(store.visibleSubscriptions.count)"
                )
                Divider().frame(height: 32)
                statCell(
                    label: "Per day",
                    value: (store.totalSubscriptionCostMonthly / 30.5).formatted(.currency(code: "CAD").presentation(.standard))
                )
            }
            .padding(.vertical, 14)
        }
        .background(Color.hhCard)
        .cornerRadius(18)
        .shadow(color: Color.hhInk.opacity(0.06), radius: 10, x: 0, y: 3)
    }

    private func statCell(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.hhInk)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.hhFaint)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Active Subscriptions

    private var activeSubscriptionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Active", subtitle: "\(store.visibleSubscriptions.count)")

            VStack(spacing: 0) {
                ForEach(store.visibleSubscriptions) { sub in
                    SubscriptionDetailRow(sub: sub) {
                        withAnimation(.spring(response: 0.3)) {
                            store.dismissSubscription(id: sub.id)
                        }
                    }
                    if sub.id != store.visibleSubscriptions.last?.id {
                        Divider().padding(.leading, 64)
                    }
                }
            }
            .background(Color.hhCard)
            .cornerRadius(18)
            .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
        }
    }

    // MARK: - Dismissed

    private var dismissedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.3)) { showDismissed.toggle() }
            } label: {
                HStack {
                    Text("Hidden (\(dismissedSubs.count))")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.hhSub)
                    Spacer()
                    Image(systemName: showDismissed ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12))
                        .foregroundColor(.hhFaint)
                }
            }
            .buttonStyle(.plain)

            if showDismissed {
                VStack(spacing: 0) {
                    ForEach(dismissedSubs) { sub in
                        HStack(spacing: 14) {
                            Text(sub.emoji)
                                .font(.system(size: 18))
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Color.hhShell))
                            Text(sub.merchantName)
                                .font(.system(size: 14))
                                .foregroundColor(.hhFaint)
                            Spacer()
                            Text(sub.amount, format: .currency(code: "CAD"))
                                .font(.system(size: 13))
                                .foregroundColor(.hhFaint)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        if sub.id != dismissedSubs.last?.id {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(Color.hhCard)
                .cornerRadius(18)
                .shadow(color: Color.hhInk.opacity(0.04), radius: 6, x: 0, y: 2)
            }
        }
    }

    // MARK: - Savings Opportunity

    private var savingsOpportunitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Savings opportunities")

            savingsCard(
                emoji: "🎵",
                title: "Music streaming",
                body: "You may be paying for Spotify and Apple Music. Consider keeping just one.",
                saving: 11.99
            )

            savingsCard(
                emoji: "💪",
                title: "Gym + fitness apps",
                body: "You have GoodLife Fitness active. Check if you're using it enough to justify the cost.",
                saving: nil
            )
        }
    }

    private func savingsCard(emoji: String, title: String, body: String, saving: Double?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(emoji).font(.system(size: 20))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.hhInk)
                Spacer()
                if let s = saving {
                    Text("Save \(s, format: .currency(code: "CAD"))/mo")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.hhGreen)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.hhGreen.opacity(0.1))
                        .cornerRadius(6)
                }
            }
            Text(body)
                .font(.system(size: 13))
                .foregroundColor(.hhSub)
        }
        .padding(14)
        .background(Color.hhCard)
        .cornerRadius(14)
        .shadow(color: Color.hhInk.opacity(0.04), radius: 5, x: 0, y: 1)
    }
}

// MARK: - Subscription Detail Row

struct SubscriptionDetailRow: View {
    let sub: DetectedSubscription
    let onDismiss: () -> Void

    @State private var showActions = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3)) { showActions.toggle() }
            } label: {
                HStack(spacing: 14) {
                    Text(sub.emoji)
                        .font(.system(size: 20))
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Color.hhShell))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(sub.merchantName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.hhInk)
                        if sub.hasIncreased, let inc = sub.increaseAmount {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold))
                                Text("Up \(inc, format: .currency(code: "CAD"))")
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.orange)
                        } else {
                            Text("Last: \(sub.lastCharge.formatted(date: .abbreviated, time: .omitted))")
                                .font(.system(size: 12))
                                .foregroundColor(.hhFaint)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(sub.amount, format: .currency(code: "CAD"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.hhInk)
                        Text(sub.annualCost, format: .currency(code: "CAD").presentation(.standard))
                            .font(.system(size: 10))
                            .foregroundColor(.hhFaint)
                        + Text("/yr").font(.system(size: 10)).foregroundColor(.hhFaint)
                    }

                    Image(systemName: showActions ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11))
                        .foregroundColor(.hhFaint)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if showActions {
                Divider().padding(.leading, 16)
                HStack(spacing: 10) {
                    Button(action: onDismiss) {
                        Text("Hide from list")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.hhSub)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.hhShell)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)

                    // Phase 7: cancellation integration
                    Button {} label: {
                        Text("Find alternative")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.hhAccent)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }
}

#Preview {
    SubscriptionManagerView()
        .environment(FinancialStore(provider: PlaidSandboxProvider()))
}
