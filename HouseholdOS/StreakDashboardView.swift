import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Haptic Helpers

private func hapticImpact(light: Bool = false) {
    #if canImport(UIKit)
    UIImpactFeedbackGenerator(style: light ? .light : .medium).impactOccurred()
    #endif
}
private func hapticSuccess() {
    #if canImport(UIKit)
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    #endif
}

// MARK: - Main Dashboard

struct StreakDashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HouseholdTask.sortOrder) private var tasks: [HouseholdTask]

    @State private var showAddTask = false
    @State private var ringAnimated = false
    @State private var selectedCategory: String? = nil
    @State private var celebrationScale: CGFloat = 1.0

    private var filteredTasks: [HouseholdTask] {
        guard let cat = selectedCategory else { return tasks }
        return tasks.filter { $0.category == cat }
    }

    private var completedCount: Int { filteredTasks.filter(\.isCompletedToday).count }
    private var totalCount: Int { filteredTasks.count }

    private var todayProgress: Double {
        tasks.isEmpty ? 0 : Double(tasks.filter(\.isCompletedToday).count) / Double(tasks.count)
    }

    private var householdStreak: Int {
        guard !tasks.isEmpty else { return 0 }
        let cal = Calendar.current
        var checkDate = cal.startOfDay(for: Date())
        var streak = 0
        while true {
            let allDone = tasks.allSatisfy { task in
                task.completions.contains { cal.startOfDay(for: $0.date) == checkDate }
            }
            guard allDone else { break }
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: checkDate) else { break }
            checkDate = prev
        }
        return streak
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        if h < 12 { return "Good morning" }
        if h < 17 { return "Good afternoon" }
        return "Good evening"
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.hhBg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 28) {
                    headerSection
                    streakRingSection
                    categoryFilterSection
                    tasksSection
                    Spacer(minLength: 110)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }

            // Floating Add Button
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
        .sheet(isPresented: $showAddTask) {
            AddTaskView()
        }
        .onAppear {
            withAnimation(.spring(response: 1.0, dampingFraction: 0.75).delay(0.25)) {
                ringAnimated = true
            }
            seedIfNeeded()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(greeting)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.hhFaint)
                Text("Household OS")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.hhInk)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(Date(), format: .dateTime.weekday(.abbreviated))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.hhFaint)
                Text(Date(), format: .dateTime.month(.abbreviated).day())
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.hhInk)
            }
        }
    }

    // MARK: - Streak Ring

    private var streakRingSection: some View {
        VStack(spacing: 20) {
            ZStack {
                // Card backing
                Circle()
                    .fill(Color.hhCard)
                    .frame(width: 224, height: 224)
                    .shadow(color: Color.hhInk.opacity(0.07), radius: 24, x: 0, y: 8)

                // Track
                Circle()
                    .stroke(Color.hhFaint.opacity(0.25), lineWidth: 18)
                    .frame(width: 190, height: 190)

                // Progress arc
                Circle()
                    .trim(from: 0, to: ringAnimated ? todayProgress : 0)
                    .stroke(Color.hhAccent, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                    .frame(width: 190, height: 190)
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.85, dampingFraction: 0.72), value: todayProgress)

                // Center
                ringCenter
            }
            .scaleEffect(celebrationScale)

            // Stat chips
            HStack(spacing: 10) {
                StatChip(value: "\(tasks.filter(\.isCompletedToday).count)/\(tasks.count)",
                         label: "Done today",
                         icon: "checkmark.circle.fill",
                         color: .hhAccent)
                StatChip(value: "\(householdStreak)",
                         label: householdStreak == 1 ? "Day streak" : "Days streak",
                         icon: "flame.fill",
                         color: .orange)
            }
        }
    }

    @ViewBuilder
    private var ringCenter: some View {
        if tasks.isEmpty {
            VStack(spacing: 6) {
                Text("🏠").font(.system(size: 40))
                Text("Add a task").font(.system(size: 14, weight: .medium)).foregroundColor(.hhFaint)
            }
        } else if todayProgress >= 1.0 {
            VStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.hhAccent)
                Text("All done!")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.hhInk)
                Text("Great work 🎉")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.hhFaint)
            }
        } else if householdStreak > 0 {
            VStack(spacing: 2) {
                Text("🔥").font(.system(size: 30))
                Text("\(householdStreak)")
                    .font(.system(size: 50, weight: .bold))
                    .foregroundColor(.hhInk)
                Text("day streak")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.hhFaint)
            }
        } else {
            VStack(spacing: 4) {
                Text("\(tasks.filter(\.isCompletedToday).count)/\(tasks.count)")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundColor(.hhInk)
                Text("today")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.hhFaint)
            }
        }
    }

    // MARK: - Category Filter

    private var categoryFilterSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                CategoryChip(label: "All", icon: "square.grid.2x2", isSelected: selectedCategory == nil) {
                    withAnimation(.spring(response: 0.3)) { selectedCategory = nil }
                }
                ForEach(TaskCategory.allCases) { cat in
                    CategoryChip(label: cat.label, icon: cat.icon, color: cat.color,
                                 isSelected: selectedCategory == cat.rawValue) {
                        withAnimation(.spring(response: 0.3)) {
                            selectedCategory = selectedCategory == cat.rawValue ? nil : cat.rawValue
                        }
                    }
                }
            }
            .padding(.horizontal, 1)
        }
    }

    // MARK: - Tasks

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(selectedCategory == nil ? "All Tasks" :
                     (TaskCategory(rawValue: selectedCategory!)?.label ?? "Tasks"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.hhInk)
                Spacer()
                if !filteredTasks.isEmpty {
                    Text("\(completedCount) of \(totalCount)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.hhFaint)
                }
            }

            if filteredTasks.isEmpty {
                emptyState
            } else {
                ForEach(filteredTasks) { task in
                    TaskCardView(task: task) {
                        toggleTask(task)
                    } onDelete: {
                        deleteTask(task)
                    }
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .scale(scale: 0.85).combined(with: .opacity)
                    ))
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text(selectedCategory != nil ? "🔍" : "🏠")
                .font(.system(size: 48))
            Text(selectedCategory != nil ? "No tasks here yet" : "No tasks yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.hhInk)
            Text(selectedCategory != nil
                 ? "Tap + to add a task in this category"
                 : "Tap + to start tracking\nyour household streaks")
                .font(.system(size: 14))
                .foregroundColor(.hhFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    // MARK: - Actions

    private func toggleTask(_ task: HouseholdTask) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            if task.isCompletedToday {
                let toRemove = task.completions.filter { cal.startOfDay(for: $0.date) == today }
                toRemove.forEach { modelContext.delete($0) }
            } else {
                let completion = DailyCompletion(date: Date())
                modelContext.insert(completion)
                task.completions.append(completion)
                hapticImpact()
                // Celebrate if all done
                if tasks.filter(\.isCompletedToday).count == tasks.count {
                    celebrateAllDone()
                }
            }
        }
    }

    private func deleteTask(_ task: HouseholdTask) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            modelContext.delete(task)
        }
    }

    private func celebrateAllDone() {
        hapticSuccess()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
            celebrationScale = 1.08
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                celebrationScale = 1.0
            }
        }
    }

    private func seedIfNeeded() {
        guard tasks.isEmpty else { return }
        let seeds: [(String, String, String, Int)] = [
            ("Dishes",          "🍽️", "chore",    0),
            ("Sweep Floor",     "🧹", "chore",    1),
            ("Take Out Trash",  "🗑️", "chore",    2),
            ("Laundry",         "👕", "chore",    3),
            ("Electric Bill",   "⚡️", "bill",     4),
            ("Internet Bill",   "📡", "bill",     5),
            ("Paper Towels",    "🧻", "supply",   6),
            ("Dish Soap",       "🫧", "supply",   7),
            ("HVAC Filter",     "🌀", "maintain", 8),
            ("Check Smoke Alarms","🔔","maintain", 9),
        ]
        for (name, emoji, cat, order) in seeds {
            let task = HouseholdTask(name: name, emoji: emoji, category: cat, sortOrder: order)
            modelContext.insert(task)
        }
    }
}

// MARK: - Stat Chip

struct StatChip: View {
    let value: String
    let label: String
    let icon: String
    var color: Color = .hhAccent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.hhInk)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.hhFaint)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.hhCard)
        .cornerRadius(14)
        .shadow(color: Color.hhInk.opacity(0.05), radius: 6, x: 0, y: 2)
    }
}

// MARK: - Category Chip

struct CategoryChip: View {
    let label: String
    let icon: String
    var color: Color = .hhAccent
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(isSelected ? .white : .hhSub)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? color : Color.hhCard)
            .cornerRadius(20)
            .shadow(color: Color.hhInk.opacity(isSelected ? 0 : 0.05), radius: 4, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Task Card

struct TaskCardView: View {
    let task: HouseholdTask
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var dragOffset: CGFloat = 0
    private let revealWidth: CGFloat = 80

    var categoryColor: Color {
        TaskCategory(rawValue: task.category)?.color ?? .hhAccent
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // Delete reveal
            Button {
                withAnimation(.spring(response: 0.3)) { onDelete() }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Delete")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(width: revealWidth, height: 76)
                .background(Color.red.opacity(0.85))
                .cornerRadius(16)
            }
            .opacity(dragOffset < -12 ? 1 : 0)

            // Card
            cardContent
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

    private var cardContent: some View {
        HStack(spacing: 14) {
            // Emoji bubble
            Text(task.emoji)
                .font(.system(size: 22))
                .frame(width: 46, height: 46)
                .background(
                    Circle().fill(
                        task.isCompletedToday
                            ? categoryColor.opacity(0.15)
                            : Color.hhBg
                    )
                )

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(task.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(task.isCompletedToday ? .hhFaint : .hhInk)
                    .strikethrough(task.isCompletedToday, color: .hhFaint)

                HStack(spacing: 6) {
                    if task.currentStreak > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                            Text("\(task.currentStreak)d streak")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.hhSub)
                        }
                    } else {
                        Text("Start your streak")
                            .font(.system(size: 11))
                            .foregroundColor(.hhFaint)
                    }

                    if task.bestStreak > 1 {
                        Text("· best \(task.bestStreak)d")
                            .font(.system(size: 11))
                            .foregroundColor(.hhFaint)
                    }
                }
            }

            Spacer()

            // Complete toggle
            Button(action: onToggle) {
                ZStack {
                    Circle()
                        .stroke(task.isCompletedToday ? categoryColor : Color.hhFaint, lineWidth: 2)
                        .frame(width: 30, height: 30)
                    if task.isCompletedToday {
                        Circle()
                            .fill(categoryColor)
                            .frame(width: 30, height: 30)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: task.isCompletedToday)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(Color.hhCard)
        .cornerRadius(16)
        .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
    }
}

// MARK: - Add Task View

struct AddTaskView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \HouseholdTask.sortOrder) private var tasks: [HouseholdTask]

    @State private var name = ""
    @State private var selectedEmoji = "🏠"
    @State private var selectedCategory: TaskCategory = .chore
    @FocusState private var nameFocused: Bool

    private let emojiOptions: [String: [String]] = [
        "chore":    ["🧹", "🍽️", "🛒", "👕", "🗑️", "✨", "🪣", "🧺", "🛁", "🪟", "🛏️", "🧴"],
        "bill":     ["⚡️", "💧", "📡", "📱", "🏠", "🔥", "💳", "📮", "🏦", "💡", "🛡️", "📋"],
        "supply":   ["🧻", "🫧", "🧽", "🪥", "🛍️", "🥫", "🧃", "🫙", "🧈", "🫒", "🥤", "🍞"],
        "maintain": ["🔧", "🌀", "🔔", "🪚", "🔑", "🧰", "🪜", "💧", "🌿", "🪴", "🔩", "🛠️"],
    ]

    private var currentEmojis: [String] {
        emojiOptions[selectedCategory.rawValue] ?? []
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.hhBg.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        // Preview
                        previewCard

                        // Name
                        inputSection(title: "TASK NAME") {
                            TextField("e.g. Do the dishes", text: $name)
                                .font(.system(size: 16))
                                .foregroundColor(.hhInk)
                                .padding(14)
                                .background(Color.hhCard)
                                .cornerRadius(12)
                                .focused($nameFocused)
                        }

                        // Category
                        inputSection(title: "CATEGORY") {
                            HStack(spacing: 8) {
                                ForEach(TaskCategory.allCases) { cat in
                                    Button {
                                        withAnimation(.spring(response: 0.3)) {
                                            selectedCategory = cat
                                            if let first = emojiOptions[cat.rawValue]?.first {
                                                selectedEmoji = first
                                            }
                                        }
                                    } label: {
                                        VStack(spacing: 4) {
                                            Image(systemName: cat.icon)
                                                .font(.system(size: 14))
                                            Text(cat.label)
                                                .font(.system(size: 10, weight: .semibold))
                                        }
                                        .foregroundColor(selectedCategory == cat ? .white : .hhSub)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(selectedCategory == cat ? cat.color : Color.hhCard)
                                        .cornerRadius(10)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        // Emoji picker
                        inputSection(title: "EMOJI") {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                                ForEach(currentEmojis, id: \.self) { emoji in
                                    Button {
                                        withAnimation(.spring(response: 0.2)) { selectedEmoji = emoji }
                                        hapticImpact(light: true)
                                    } label: {
                                        Text(emoji)
                                            .font(.system(size: 22))
                                            .frame(width: 46, height: 46)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(selectedEmoji == emoji
                                                          ? selectedCategory.color.opacity(0.15)
                                                          : Color.hhCard)
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(selectedEmoji == emoji ? selectedCategory.color : Color.clear, lineWidth: 2)
                                            )
                                            .scaleEffect(selectedEmoji == emoji ? 1.08 : 1.0)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        Spacer(minLength: 16)

                        // Add button
                        Button { addTask() } label: {
                            Text("Add Task")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(
                                    name.trimmingCharacters(in: .whitespaces).isEmpty
                                        ? Color.hhFaint : selectedCategory.color
                                )
                                .cornerRadius(14)
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("New Task")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.hhAccent)
                }
            }
        }
        .onAppear { nameFocused = true }
    }

    private var previewCard: some View {
        HStack(spacing: 14) {
            Text(selectedEmoji)
                .font(.system(size: 26))
                .frame(width: 48, height: 48)
                .background(Circle().fill(selectedCategory.color.opacity(0.12)))

            VStack(alignment: .leading, spacing: 3) {
                Text(name.isEmpty ? "Task name" : name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(name.isEmpty ? .hhFaint : .hhInk)
                HStack(spacing: 4) {
                    Image(systemName: selectedCategory.icon)
                        .font(.system(size: 10))
                    Text(selectedCategory.label)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(selectedCategory.color)
            }
            Spacer()
            ZStack {
                Circle()
                    .stroke(Color.hhFaint, lineWidth: 2)
                    .frame(width: 28, height: 28)
            }
        }
        .padding(16)
        .background(Color.hhCard)
        .cornerRadius(16)
        .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    @ViewBuilder
    private func inputSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.hhFaint)
            content()
        }
    }

    private func addTask() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let task = HouseholdTask(name: trimmed, emoji: selectedEmoji,
                                 category: selectedCategory.rawValue, sortOrder: tasks.count)
        modelContext.insert(task)
        hapticImpact()
        dismiss()
    }
}

#Preview("Dashboard") {
    StreakDashboardView()
        .modelContainer(for: [HouseholdTask.self, DailyCompletion.self], inMemory: true)
}

#Preview("Add Task") {
    AddTaskView()
        .modelContainer(for: [HouseholdTask.self, DailyCompletion.self], inMemory: true)
}
