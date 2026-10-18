import SwiftUI
import StoreKit

// MARK: - You View

struct YouView: View {
    // Phase 1: single mock user. Phase 2: loaded from Supabase auth.
    @State private var currentUser = HouseholdMember(
        name: "Alex", role: "owner", email: "alex@household.app", isCurrentUser: true
    )
    @State private var members: [HouseholdMember] = [
        HouseholdMember(name: "Alex", role: "owner", isCurrentUser: true),
        HouseholdMember(name: "Sam", role: "member"),
    ]

    @Environment(StoreKitStore.self) private var storeKitStore
    @Environment(RewardsStore.self) private var rewardsStore

    @State private var showOSPlus = false
    @State private var showRewards = false
    @State private var showNotificationSettings = false
    @State private var notificationsEnabled = true
    @State private var morningBrief = true
    @State private var paymentAlerts = true
    @State private var maintenanceReminders = true

    var body: some View {
        ZStack {
            Color.hhBg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    profileSection
                    householdSection
                    osPlusSection
                    connectedAccountsSection
                    notificationsSection
                    privacySection
                    aboutSection
                    Spacer(minLength: 80)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
        }
        .navigationTitle("You")
        .hhNavTitleStyle(.large)
        .sheet(isPresented: $showOSPlus) {
            PaywallView()
                .environment(storeKitStore)
        }
        .navigationDestination(isPresented: $showRewards) {
            RewardsView()
                .environment(rewardsStore)
        }
    }

    // MARK: - Profile

    private var profileSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                initialsAvatar(name: currentUser.name, size: 56, fontSize: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(currentUser.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.hhInk)
                    Text(currentUser.email ?? "")
                        .font(.system(size: 13))
                        .foregroundColor(.hhSub)
                    Text(currentUser.role.capitalized)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.hhAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.hhAccent.opacity(0.1))
                        .cornerRadius(6)
                }
                Spacer()
                Image(systemName: "pencil.circle")
                    .font(.system(size: 22))
                    .foregroundColor(.hhFaint)
            }
            .padding(18)
        }
        .background(Color.hhCard)
        .cornerRadius(18)
        .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    // MARK: - Household

    private var householdSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Household", subtitle: "\(members.count) members")

            VStack(spacing: 0) {
                ForEach(members) { member in
                    HStack(spacing: 14) {
                        initialsAvatar(name: member.name, size: 38, fontSize: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(member.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.hhInk)
                                if member.isCurrentUser {
                                    Text("You")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.hhAccent)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.hhAccent.opacity(0.1))
                                        .cornerRadius(4)
                                }
                            }
                            Text(member.role.capitalized)
                                .font(.system(size: 12))
                                .foregroundColor(.hhFaint)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    if member.id != members.last?.id {
                        Divider().padding(.leading, 68)
                    }
                }

                Divider()

                Button {
                    // Phase 2: invite flow
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 16))
                            .foregroundColor(.hhAccent)
                        Text("Invite a household member")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.hhAccent)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            }
            .background(Color.hhCard)
            .cornerRadius(18)
            .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
        }
    }

    // MARK: - OS+

    private var osPlusSection: some View {
        Button { showOSPlus = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "star.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(
                        LinearGradient(colors: [.yellow, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Household OS+")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.hhInk)
                        if storeKitStore.isPremium {
                            Text("ACTIVE")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.hhGreen)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.hhGreen.opacity(0.12))
                                .cornerRadius(4)
                        } else {
                            Text("FROM $4.99/MO")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.hhAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.hhAccent.opacity(0.12))
                                .cornerRadius(4)
                        }
                    }
                    Text(storeKitStore.isPremium
                         ? (storeKitStore.activeProduct?.displayName ?? "Premium active")
                         : "Safe AutoPay, unlimited accounts, advanced automation")
                        .font(.system(size: 12))
                        .foregroundColor(.hhSub)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.hhFaint)
            }
            .padding(16)
            .background(Color.hhCard)
            .cornerRadius(18)
            .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Connected Accounts

    private var connectedAccountsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Connected Accounts")
            settingsGroup {
                settingsRow(icon: "building.columns", label: "Financial Accounts",
                            value: FeatureFlags.financialConnections ? "Connected" : "Not connected",
                            valueColor: FeatureFlags.financialConnections ? .hhGreen : .hhFaint)
                Divider().padding(.leading, 52)
                settingsRow(icon: "creditcard", label: "Payment Methods",
                            value: FeatureFlags.vopayPayments ? "Linked" : "Not linked",
                            valueColor: .hhFaint)
                Divider().padding(.leading, 52)
                if FeatureFlags.householdRewards {
                    Button { showRewards = true } label: {
                        settingsRow(
                            icon: "gift.circle",
                            label: "Rewards",
                            value: rewardsStore.hasBalance
                                ? rewardsStore.balance.confirmed.formatted(.currency(code: "CAD"))
                                : "Active",
                            valueColor: .hhGreen
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    settingsRow(icon: "gift.circle", label: "Rewards",
                                value: "Not set up", valueColor: .hhFaint)
                }
            }
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Notifications")
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "bell")
                        .font(.system(size: 16))
                        .foregroundColor(.hhAccent)
                        .frame(width: 36)
                    Text("Notifications")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.hhInk)
                    Spacer()
                    Toggle("", isOn: $notificationsEnabled)
                        .tint(.hhAccent)
                        .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                if notificationsEnabled {
                    Divider().padding(.leading, 52)
                    notificationToggle(icon: "sun.horizon", label: "Morning brief", binding: $morningBrief)
                    Divider().padding(.leading, 52)
                    notificationToggle(icon: "dollarsign.circle", label: "Payment alerts", binding: $paymentAlerts)
                    Divider().padding(.leading, 52)
                    notificationToggle(icon: "wrench.and.screwdriver", label: "Maintenance reminders", binding: $maintenanceReminders)
                }
            }
            .background(Color.hhCard)
            .cornerRadius(18)
            .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
        }
    }

    private func notificationToggle(icon: String, label: String, binding: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.hhSub)
                .frame(width: 36)
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(.hhInk)
            Spacer()
            Toggle("", isOn: binding)
                .tint(.hhAccent)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Privacy

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Privacy & Security")
            settingsGroup {
                settingsRow(icon: "lock.shield", label: "Privacy Policy", value: "")
                Divider().padding(.leading, 52)
                settingsRow(icon: "doc.text", label: "Terms of Service", value: "")
                Divider().padding(.leading, 52)
                settingsRow(icon: "square.and.arrow.up", label: "Export my data", value: "")
                Divider().padding(.leading, 52)
                Button {
                    // Phase 2: delete account flow with confirmation
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "trash")
                            .font(.system(size: 16))
                            .foregroundColor(.red)
                            .frame(width: 36)
                        Text("Delete account")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.red)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "About")
            settingsGroup {
                settingsRow(icon: "info.circle", label: "Version",
                            value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                Divider().padding(.leading, 52)
                settingsRow(icon: "envelope", label: "Contact support", value: "")
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Color.hhCard)
        .cornerRadius(18)
        .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    private func settingsRow(icon: String, label: String, value: String, valueColor: Color = .hhFaint) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.hhAccent)
                .frame(width: 36)
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.hhInk)
            Spacer()
            if !value.isEmpty {
                Text(value)
                    .font(.system(size: 14))
                    .foregroundColor(valueColor)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color.hhFaint.opacity(0.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func initialsAvatar(name: String, size: CGFloat, fontSize: CGFloat) -> some View {
        let initials = name.components(separatedBy: " ")
            .compactMap { $0.first.map(String.init) }.joined()
        return Text(initials)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(Color.hhAccent)
            .clipShape(Circle())
    }
}

#Preview {
    NavigationStack { YouView() }
        .environment(StoreKitStore())
        .environment(RewardsStore(provider: WildfireSandboxProvider()))
}
