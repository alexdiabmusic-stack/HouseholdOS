import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Home View

struct HomeView: View {
    @Query private var maintenance: [MaintenanceTask]
    @Query(sort: \HouseholdTask.sortOrder) private var tasks: [HouseholdTask]
    @Environment(ServiceMarketplaceStore.self) private var marketplaceStore

    private var overdueCount: Int { maintenance.filter { $0.isOverdue && !$0.isComplete }.count }
    private var dueSoonCount: Int { maintenance.filter { $0.isDueSoon && !$0.isComplete }.count }

    var body: some View {
        ZStack {
            Color.hhBg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    NavigationLink(destination: RoutinesDestination()) {
                        HomeSection(
                            emoji: "✅",
                            title: "Routines",
                            subtitle: routinesSubtitle,
                            badge: nil,
                            badgeColor: .hhGreen
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink(destination: MaintenanceView()) {
                        HomeSection(
                            emoji: "🔧",
                            title: "Maintenance",
                            subtitle: maintenanceSubtitle,
                            badge: overdueCount > 0 ? "\(overdueCount)" : nil,
                            badgeColor: .red
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink(destination: servicesDestination) {
                        HomeSection(
                            emoji: "🏠",
                            title: "Services",
                            subtitle: servicesSubtitle,
                            badge: nil,
                            badgeColor: .hhAccent
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink(destination: AppliancesPlaceholder()) {
                        HomeSection(
                            emoji: "🧰",
                            title: "Appliances & Inventory",
                            subtitle: "Warranties, manuals, and receipts",
                            badge: nil,
                            badgeColor: .hhBlue
                        )
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 80)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
        }
        .navigationTitle("Home")
        .hhNavTitleStyle(.large)
    }

    private var routinesSubtitle: String {
        let done = tasks.filter(\.isCompletedToday).count
        let total = tasks.count
        if total == 0 { return "No routines yet" }
        if done == total { return "All \(total) done today ✓" }
        return "\(done) of \(total) done today"
    }

    @ViewBuilder
    private var servicesDestination: some View {
        if FeatureFlags.serviceMarketplace {
            ServiceMarketplaceView()
        } else {
            ServicesPlaceholder()
        }
    }

    private var servicesSubtitle: String {
        if FeatureFlags.serviceMarketplace {
            let count = marketplaceStore.upcomingBookings.count
            if count > 0 { return "\(count) upcoming booking\(count == 1 ? "" : "s")" }
            return "Book cleaning, HVAC, plumbing & more"
        }
        return "Book cleaning, HVAC, plumbing & more"
    }

    private var maintenanceSubtitle: String {
        if overdueCount > 0 { return "\(overdueCount) overdue · \(dueSoonCount) due soon" }
        if dueSoonCount > 0 { return "\(dueSoonCount) due this week" }
        let total = maintenance.filter { !$0.isComplete }.count
        if total == 0 { return "Nothing scheduled" }
        return "\(total) upcoming"
    }
}

// MARK: - Home Section Row

struct HomeSection: View {
    let emoji: String
    let title: String
    let subtitle: String
    let badge: String?
    let badgeColor: Color

    var body: some View {
        HStack(spacing: 16) {
            Text(emoji)
                .font(.system(size: 24))
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.hhShell))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.hhInk)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(.hhSub)
                    .lineLimit(1)
            }

            Spacer()

            if let badge = badge {
                Text(badge)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .frame(minWidth: 24, minHeight: 24)
                    .padding(.horizontal, 4)
                    .background(badgeColor)
                    .clipShape(Capsule())
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.hhFaint)
        }
        .padding(16)
        .background(Color.hhCard)
        .cornerRadius(18)
        .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
    }
}

// MARK: - Routines Destination (wraps existing StreakDashboardView)

struct RoutinesDestination: View {
    var body: some View {
        StreakDashboardView()
            .hhHideNavigationBar()
            .overlay(alignment: .topLeading) {
                // Custom back button since we hide the nav bar
                BackButton()
                    .padding(.top, 54)
                    .padding(.leading, 16)
            }
    }
}

struct BackButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button {
            dismiss()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                Text("Home")
                    .font(.system(size: 16, weight: .medium))
            }
            .foregroundColor(.hhAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Maintenance View

struct MaintenanceView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var tasks: [MaintenanceTask]

    @State private var showAddTask = false
    @State private var showCompleted = false

    private var activeTasks: [MaintenanceTask] {
        tasks.filter { !$0.isComplete }.sorted { lhs, rhs in
            let lPri = priority(lhs)
            let rPri = priority(rhs)
            if lPri != rPri { return lPri < rPri }
            if let ld = lhs.dueDate, let rd = rhs.dueDate { return ld < rd }
            return lhs.createdAt < rhs.createdAt
        }
    }
    private var completedTasks: [MaintenanceTask] {
        tasks.filter { $0.isComplete }.sorted { ($0.completedDate ?? .distantPast) > ($1.completedDate ?? .distantPast) }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.hhBg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    if activeTasks.isEmpty && completedTasks.isEmpty {
                        emptyState
                    } else {
                        ForEach(activeTasks) { task in
                            MaintenanceTaskRow(task: task, onComplete: { complete(task) }, onDelete: { delete(task) })
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .scale(scale: 0.85).combined(with: .opacity)
                                ))
                        }

                        if !completedTasks.isEmpty {
                            Button {
                                withAnimation(.spring(response: 0.3)) { showCompleted.toggle() }
                            } label: {
                                HStack {
                                    Text(showCompleted ? "Hide completed" : "Show completed (\(completedTasks.count))")
                                    Spacer()
                                    Image(systemName: showCompleted ? "chevron.up" : "chevron.down")
                                }
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.hhSub)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)

                            if showCompleted {
                                ForEach(completedTasks) { task in
                                    MaintenanceTaskRow(task: task, onComplete: nil, onDelete: { delete(task) })
                                }
                            }
                        }
                    }
                    Spacer(minLength: 110)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }

            Button { showAddTask = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 64, height: 64)
                    .background(Color.hhAccent)
                    .clipShape(Circle())
                    .shadow(color: Color.hhAccent.opacity(0.4), radius: 16, x: 0, y: 6)
            }
            .padding(.trailing, 24)
            .padding(.bottom, 44)
        }
        .navigationTitle("Maintenance")
        .hhNavTitleStyle(.large)
        .sheet(isPresented: $showAddTask) {
            AddMaintenanceTaskSheet()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Text("🔧").font(.system(size: 56))
            Text("No maintenance scheduled")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.hhInk)
            Text("Tap + to add a maintenance task\nor recurring home item")
                .font(.system(size: 14))
                .foregroundColor(.hhFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func priority(_ task: MaintenanceTask) -> Int {
        if task.isOverdue { return 0 }
        if task.isDueSoon { return 1 }
        switch task.priority {
        case "urgent": return 2
        case "high":   return 3
        case "medium": return 4
        default:       return 5
        }
    }

    private func complete(_ task: MaintenanceTask) {
        withAnimation(.spring(response: 0.35)) {
            task.completedDate = Date()
            if let interval = task.intervalDays,
               let next = Calendar.current.date(byAdding: .day, value: interval, to: Date()) {
                // Create next recurrence
                let next = MaintenanceTask(name: task.name, emoji: task.emoji,
                                           category: task.category, notes: task.notes,
                                           dueDate: next, isDIY: task.isDIY,
                                           priority: task.priority, intervalDays: interval)
                modelContext.insert(next)
            }
        }
#if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
#endif
    }

    private func delete(_ task: MaintenanceTask) {
        withAnimation(.spring(response: 0.35)) { modelContext.delete(task) }
    }
}

// MARK: - Maintenance Task Row

struct MaintenanceTaskRow: View {
    let task: MaintenanceTask
    let onComplete: (() -> Void)?
    let onDelete: () -> Void
    @State private var dragOffset: CGFloat = 0
    private let revealWidth: CGFloat = 80

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onDelete) {
                VStack(spacing: 4) {
                    Image(systemName: "trash.fill").font(.system(size: 14, weight: .semibold))
                    Text("Delete").font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(width: revealWidth, height: 72)
                .background(Color.red.opacity(0.85))
                .cornerRadius(16)
            }
            .opacity(dragOffset < -12 ? 1 : 0)

            rowContent
                .offset(x: dragOffset)
                .gesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .local)
                        .onChanged { val in
                            if val.translation.width < 0 {
                                dragOffset = max(val.translation.width, -revealWidth)
                            } else if dragOffset < 0 {
                                dragOffset = min(dragOffset + val.translation.width, 0)
                            }
                        }
                        .onEnded { val in
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                dragOffset = val.translation.width < -(revealWidth / 2) ? -revealWidth : 0
                            }
                        }
                )
        }
        .clipped()
    }

    private var rowContent: some View {
        HStack(spacing: 14) {
            Text(task.emoji)
                .font(.system(size: 22))
                .frame(width: 46, height: 46)
                .background(Circle().fill(statusColor.opacity(0.12)))

            VStack(alignment: .leading, spacing: 4) {
                Text(task.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(task.isComplete ? .hhFaint : .hhInk)
                    .strikethrough(task.isComplete, color: .hhFaint)

                HStack(spacing: 6) {
                    Image(systemName: statusIcon).font(.system(size: 10))
                    Text(statusLabel).font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(task.isComplete ? .hhGreen : statusColor)
            }

            Spacer()

            if let action = onComplete, !task.isComplete {
                Button(action: action) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 24))
                        .foregroundColor(.hhFaint)
                }
                .buttonStyle(.plain)
            } else if task.isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.hhGreen)
            }
        }
        .padding(16)
        .background(Color.hhCard)
        .cornerRadius(16)
        .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    private var statusColor: Color {
        if task.isComplete { return .hhGreen }
        if task.isOverdue  { return .red }
        if task.isDueSoon  { return .orange }
        return .hhSub
    }

    private var statusIcon: String {
        if task.isComplete { return "checkmark.circle.fill" }
        if task.isOverdue  { return "exclamationmark.circle" }
        if task.isDueSoon  { return "clock" }
        return "calendar"
    }

    private var statusLabel: String {
        if task.isComplete, let d = task.completedDate {
            return "Completed \(d.formatted(date: .abbreviated, time: .omitted))"
        }
        guard let due = task.dueDate else { return task.isDIY ? "DIY" : "Schedule service" }
        if task.isOverdue { return "Overdue since \(due.formatted(date: .abbreviated, time: .omitted))" }
        return "Due \(due.formatted(date: .abbreviated, time: .omitted))"
    }
}

// MARK: - Add Maintenance Task Sheet

struct AddMaintenanceTaskSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selectedEmoji = "🔧"
    @State private var notes = ""
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var isDIY = true
    @State private var priority = "medium"
    @State private var isRecurring = false
    @State private var intervalDays = 90
    @FocusState private var nameFocused: Bool

    private let emojis = ["🔧", "🌀", "🔔", "💧", "🌿", "🛠️", "🪣", "🔩", "🪟", "🔑", "🏠", "⚡️"]
    private let priorities = [("low", "Low"), ("medium", "Medium"), ("high", "High"), ("urgent", "Urgent")]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.hhBg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        // Emoji row
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(emojis, id: \.self) { emoji in
                                    Button {
                                        withAnimation(.spring(response: 0.2)) { selectedEmoji = emoji }
                                    } label: {
                                        Text(emoji)
                                            .font(.system(size: 22))
                                            .frame(width: 48, height: 48)
                                            .background(
                                                RoundedRectangle(cornerRadius: 12)
                                                    .fill(selectedEmoji == emoji ? Color.hhAccent.opacity(0.15) : Color.hhCard)
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12)
                                                    .stroke(selectedEmoji == emoji ? Color.hhAccent : Color.clear, lineWidth: 2)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 1)
                        }

                        inputField(title: "TASK NAME") {
                            TextField("e.g. Replace HVAC filter", text: $name)
                                .font(.system(size: 16))
                                .foregroundColor(.hhInk)
                                .padding(14)
                                .background(Color.hhCard)
                                .cornerRadius(12)
                                .focused($nameFocused)
                        }

                        inputField(title: "PRIORITY") {
                            HStack(spacing: 8) {
                                ForEach(priorities, id: \.0) { p in
                                    Button {
                                        withAnimation(.spring(response: 0.3)) { priority = p.0 }
                                    } label: {
                                        Text(p.1)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(priority == p.0 ? .white : .hhSub)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(priority == p.0 ? priorityColor(p.0) : Color.hhCard)
                                            .cornerRadius(10)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        inputField(title: "DUE DATE") {
                            VStack(spacing: 8) {
                                Toggle("Set a due date", isOn: $hasDueDate)
                                    .font(.system(size: 15))
                                    .foregroundColor(.hhInk)
                                    .tint(.hhAccent)
                                if hasDueDate {
                                    DatePicker("", selection: $dueDate, displayedComponents: .date)
                                        .datePickerStyle(.graphical)
                                        .tint(.hhAccent)
                                }
                            }
                            .padding(14)
                            .background(Color.hhCard)
                            .cornerRadius(12)
                        }

                        inputField(title: "RECURRING") {
                            VStack(spacing: 8) {
                                Toggle("Repeat this task", isOn: $isRecurring)
                                    .font(.system(size: 15))
                                    .foregroundColor(.hhInk)
                                    .tint(.hhAccent)
                                if isRecurring {
                                    Stepper("Every \(intervalDays) days", value: $intervalDays, in: 7...365, step: 7)
                                        .font(.system(size: 14))
                                        .foregroundColor(.hhInk)
                                }
                            }
                            .padding(14)
                            .background(Color.hhCard)
                            .cornerRadius(12)
                        }

                        Toggle("I'll do this myself (DIY)", isOn: $isDIY)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.hhInk)
                            .tint(.hhAccent)
                            .padding(14)
                            .background(Color.hhCard)
                            .cornerRadius(12)

                        Spacer(minLength: 16)

                        Button { addTask() } label: {
                            Text("Add Task")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(name.trimmingCharacters(in: .whitespaces).isEmpty ? Color.hhFaint : Color.hhAccent)
                                .cornerRadius(14)
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("New Task")
            .hhNavTitleStyle(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.hhAccent)
                }
            }
            .onAppear { nameFocused = true }
        }
    }

    @ViewBuilder
    private func inputField<C: View>(title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.hhFaint)
            content()
        }
    }

    private func priorityColor(_ p: String) -> Color {
        switch p {
        case "urgent": return .red
        case "high":   return .orange
        case "medium": return .hhAccent
        default:       return .hhSub
        }
    }

    private func addTask() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let task = MaintenanceTask(
            name: trimmed,
            emoji: selectedEmoji,
            notes: notes,
            dueDate: hasDueDate ? dueDate : nil,
            isDIY: isDIY,
            priority: priority,
            intervalDays: isRecurring ? intervalDays : nil
        )
        modelContext.insert(task)
        dismiss()
    }
}

// MARK: - Placeholder Views

struct ServicesPlaceholder: View {
    var body: some View {
        PhaseComingSoonView(
            emoji: "🏠",
            title: "Home Services",
            description: "Book cleaners, HVAC technicians, plumbers, handymen, and more — right from Household OS.",
            phase: "Phase 5"
        )
        .navigationTitle("Services")
        .hhNavTitleStyle(.large)
    }
}

struct AppliancesPlaceholder: View {
    var body: some View {
        PhaseComingSoonView(
            emoji: "🧰",
            title: "Appliances & Inventory",
            description: "Track warranties, manuals, receipts, and maintenance history for every appliance in your home.",
            phase: "Coming soon"
        )
        .navigationTitle("Appliances")
        .hhNavTitleStyle(.large)
    }
}

struct PhaseComingSoonView: View {
    let emoji: String
    let title: String
    let description: String
    let phase: String

    var body: some View {
        ZStack {
            Color.hhBg.ignoresSafeArea()
            VStack(spacing: 20) {
                Text(emoji).font(.system(size: 64)).padding(.top, 60)
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.hhInk)
                Text(description)
                    .font(.system(size: 15))
                    .foregroundColor(.hhSub)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Text(phase)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.hhAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.hhAccent.opacity(0.1))
                    .cornerRadius(20)
                Spacer()
            }
        }
    }
}

#Preview {
    NavigationStack { HomeView() }
        .modelContainer(for: [HouseholdTask.self, DailyCompletion.self, MaintenanceTask.self], inMemory: true)
}
