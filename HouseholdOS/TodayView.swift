import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Today View

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(FinancialStore.self) private var financialStore
    @Query(sort: \HouseholdTask.sortOrder) private var tasks: [HouseholdTask]
    @Query private var lists: [ShoppingList]
    @Query private var maintenance: [MaintenanceTask]

    @State private var dismissedCardKeys: Set<String> = []

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        if h < 12 { return "Good morning" }
        if h < 17 { return "Good afternoon" }
        return "Good evening"
    }

    private var activeCards: [TodayCard] {
        var cards: [TodayCard] = []
        let h = Calendar.current.component(.hour, from: Date())

        // Financial: overdue bills (highest priority)
        if FeatureFlags.financialConnections {
            for bill in financialStore.upcomingConfirmedBills where bill.isOverdue {
                cards.append(TodayCard(id: "bill-overdue-\(bill.id)", kind: .billOverdue(bill), priority: .urgent))
            }
            // Bills due within 3 days
            for bill in financialStore.upcomingConfirmedBills where bill.isDueSoon && !bill.isOverdue {
                if let days = bill.daysUntilDue, days <= 3 {
                    cards.append(TodayCard(id: "bill-due-\(bill.id)", kind: .billDue(bill), priority: .high))
                }
            }
        }

        // Phase 8: spending anomalies
        if FeatureFlags.anomalyDetection {
            for anomaly in financialStore.spendingAnomalies.prefix(2) {
                cards.append(TodayCard(
                    id: "anomaly-\(anomaly.id)",
                    kind: .spendingAnomaly(anomaly),
                    priority: anomaly.severity == .alert ? .urgent : .high
                ))
            }
        }

        // Routines: show if it's past 7am and tasks aren't all done
        if h >= 7 {
            let completed = tasks.filter(\.isCompletedToday).count
            let total = tasks.count
            if total > 0 && completed < total {
                cards.append(TodayCard(
                    id: "routines-pending",
                    kind: .routinesPending(completed: completed, total: total),
                    priority: .medium
                ))
            }
        }

        // Maintenance overdue
        for task in maintenance where task.isOverdue && !task.isComplete {
            let key = "maint-overdue-\(task.persistentModelID)"
            cards.append(TodayCard(id: key, kind: .maintenanceOverdue(task), priority: .high))
        }

        // Maintenance due soon
        for task in maintenance where task.isDueSoon && !task.isComplete {
            let key = "maint-due-\(task.persistentModelID)"
            cards.append(TodayCard(id: key, kind: .maintenanceDue(task), priority: .medium))
        }

        // Shopping lists with pending items
        for list in lists where list.pendingCount > 0 {
            let key = "grocery-\(list.persistentModelID)"
            cards.append(TodayCard(id: key, kind: .groceryListPending(list), priority: .low))
        }

        return cards
            .filter { !dismissedCardKeys.contains($0.id) }
            .sorted { $0.priority < $1.priority }
    }

    var body: some View {
        ZStack {
            Color.hhBg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    headerSection
                    if activeCards.isEmpty {
                        allGoodSection
                    } else {
                        cardsSection
                    }
                    Spacer(minLength: 80)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greeting)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.hhFaint)
            Text(Date(), format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.hhInk)
            HStack(spacing: 6) {
                if activeCards.isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.hhGreen)
                    Text("Everything looks good")
                } else {
                    Text("\(activeCards.count) thing\(activeCards.count == 1 ? "" : "s") need\(activeCards.count == 1 ? "s" : "") attention")
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(activeCards.isEmpty ? .hhGreen : .hhSub)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - All Good

    private var allGoodSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.hhGreen)
                .padding(.top, 60)
            Text("You're all caught up")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.hhInk)
            Text("Household OS will surface anything\nthat needs your attention here.")
                .font(.system(size: 14))
                .foregroundColor(.hhFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Cards

    private var cardsSection: some View {
        VStack(spacing: 12) {
            ForEach(activeCards) { card in
                TodayCardView(card: card) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        _ = dismissedCardKeys.insert(card.id)
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .scale(scale: 0.88).combined(with: .opacity)
                ))
            }
        }
    }
}

// MARK: - Today Card View

struct TodayCardView: View {
    let card: TodayCard
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Category label
            HStack {
                Image(systemName: cardIcon)
                    .font(.system(size: 11, weight: .semibold))
                Text(categoryLabel)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.hhFaint)
                        .frame(width: 28, height: 28)
                        .background(Color.hhShell)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .foregroundColor(cardColor)
            .padding(.bottom, 10)

            // Title
            Text(cardTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.hhInk)

            // Subtitle
            if !cardSubtitle.isEmpty {
                Text(cardSubtitle)
                    .font(.system(size: 13))
                    .foregroundColor(.hhSub)
                    .padding(.top, 2)
            }

            // Actions
            if !primaryAction.isEmpty || !secondaryAction.isEmpty {
                HStack(spacing: 10) {
                    if !secondaryAction.isEmpty {
                        Text(secondaryAction)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.hhSub)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.hhShell)
                            .cornerRadius(10)
                    }
                    if !primaryAction.isEmpty {
                        Text(primaryAction)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(cardColor)
                            .cornerRadius(10)
                    }
                }
                .padding(.top, 14)
            }
        }
        .padding(16)
        .background(Color.hhCard)
        .cornerRadius(18)
        .shadow(color: Color.hhInk.opacity(0.06), radius: 10, x: 0, y: 3)
    }

    private var cardColor: Color {
        switch card.kind {
        case .maintenanceOverdue:              return .red.opacity(0.85)
        case .maintenanceDue:                  return .hhPurple
        case .groceryListPending:              return .hhGreen
        case .routinesPending:                 return .hhAccent
        case .billOverdue:                     return .red.opacity(0.85)
        case .billDue:                         return .hhBlue
        case .billUnusual:                     return .orange
        case .spendingAnomaly(let a):          return a.severity == .alert ? .red.opacity(0.85) : .orange
        }
    }

    private var cardIcon: String {
        switch card.kind {
        case .maintenanceOverdue, .maintenanceDue: return "wrench.and.screwdriver"
        case .groceryListPending:                  return "cart"
        case .routinesPending:                     return "checkmark.circle"
        case .billOverdue, .billDue, .billUnusual: return "dollarsign.circle"
        case .spendingAnomaly:                     return "exclamationmark.triangle"
        }
    }

    private var categoryLabel: String {
        switch card.kind {
        case .maintenanceOverdue:     return "MAINTENANCE · OVERDUE"
        case .maintenanceDue:         return "MAINTENANCE · DUE SOON"
        case .groceryListPending:     return "GROCERY LIST"
        case .routinesPending:        return "ROUTINES"
        case .billOverdue:            return "BILL · OVERDUE"
        case .billDue:                return "BILL DUE"
        case .billUnusual:            return "UNUSUAL CHARGE"
        case .spendingAnomaly(let a): return a.kind == .unusuallyLarge ? "UNUSUAL CHARGE" : "POSSIBLE DUPLICATE"
        }
    }

    private var cardTitle: String {
        switch card.kind {
        case .maintenanceOverdue(let t): return t.name
        case .maintenanceDue(let t):     return t.name
        case .groceryListPending(let l): return l.name
        case .routinesPending(let c, let tot):
            return "\(tot - c) task\(tot - c == 1 ? "" : "s") still to do"
        case .billOverdue(let b):  return "\(b.merchantName) is overdue"
        case .billDue(let b):      return "\(b.merchantName) due soon"
        case .billUnusual(let b):  return "\(b.merchantName) — unusual amount"
        case .spendingAnomaly(let a):
            return "\(a.merchantName) — \(a.kind == .unusuallyLarge ? "unusual amount" : "possible duplicate")"
        }
    }

    private var cardSubtitle: String {
        switch card.kind {
        case .maintenanceOverdue(let t):
            if let d = t.dueDate {
                return "Was due \(d.formatted(.relative(presentation: .named)))"
            }
            return "Past due"
        case .maintenanceDue(let t):
            if let d = t.dueDate {
                return "Due \(d.formatted(.relative(presentation: .named)))"
            }
            return "Due soon"
        case .groceryListPending(let l):
            return "\(l.pendingCount) item\(l.pendingCount == 1 ? "" : "s") pending"
        case .routinesPending(let c, let tot):
            return "\(c) of \(tot) done today"
        case .billOverdue(let b):
            let amt = b.amount.formatted(.currency(code: "CAD"))
            if let d = b.predictedNextDate {
                return "\(amt) · \(d.formatted(date: .abbreviated, time: .omitted))"
            }
            return amt
        case .billDue(let b):
            let amt = b.amount.formatted(.currency(code: "CAD"))
            let days = b.daysUntilDue ?? 0
            let dateStr = days == 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days"
            return "\(amt) · due \(dateStr)"
        case .billUnusual(let b):
            return "\(b.amount.formatted(.currency(code: "CAD"))) · higher than normal"
        case .spendingAnomaly(let a):
            return a.message
        }
    }

    private var primaryAction: String {
        switch card.kind {
        case .maintenanceOverdue, .maintenanceDue: return "View"
        case .groceryListPending:                  return FeatureFlags.instacartCommerce ? "Order on Instacart" : "Open List"
        case .routinesPending:                     return "View Routines"
        case .billDue, .billOverdue, .billUnusual: return "View Bill"
        case .spendingAnomaly:                     return "View Insights"
        }
    }

    private var secondaryAction: String {
        switch card.kind {
        case .maintenanceOverdue, .maintenanceDue: return "Book Service"
        case .groceryListPending:                  return "Dismiss"
        case .routinesPending:                     return ""
        case .billDue, .billOverdue, .billUnusual: return ""
        case .spendingAnomaly:                     return ""
        }
    }
}

#Preview {
    NavigationStack { TodayView() }
        .modelContainer(for: [HouseholdTask.self, DailyCompletion.self,
                               ShoppingList.self, ListItem.self, MaintenanceTask.self],
                        inMemory: true)
}
