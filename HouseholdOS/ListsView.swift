import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Lists View

struct ListsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(GrocerySessionStore.self) private var groceryStore
    @Query(sort: \ShoppingList.sortOrder) private var lists: [ShoppingList]

    @State private var showAddList = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.hhBg.ignoresSafeArea()
            Group {
                if lists.isEmpty {
                    emptyState
                } else {
                    listsGrid
                }
            }

            Button { showAddList = true } label: {
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
        .navigationTitle("Lists")
        .hhNavTitleStyle(.large)
        .sheet(isPresented: $showAddList) {
            AddListSheet()
        }
    }

    // MARK: - Grid

    private var listsGrid: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                spacing: 14
            ) {
                ForEach(lists) { list in
                    NavigationLink(destination: ListDetailView(list: list)) {
                        ListCard(
                            list: list,
                            lastOrderedAt: groceryStore.lastSession(forListNamed: list.name)?.startedAt
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 110)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Text("🛒").font(.system(size: 56))
            Text("No lists yet")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.hhInk)
            Text("Tap + to create your first\ngrocery or shopping list")
                .font(.system(size: 14))
                .foregroundColor(.hhFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - List Card

struct ListCard: View {
    let list: ShoppingList
    var lastOrderedAt: Date? = nil

    private static let instacartGreen = Color(red: 0.19, green: 0.62, blue: 0.25)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(list.emoji)
                    .font(.system(size: 28))
                Spacer()
                if list.pendingCount > 0 {
                    Text("\(list.pendingCount)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Color.hhAccent)
                        .clipShape(Circle())
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(list.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.hhInk)
                    .lineLimit(1)
                Text(itemCountLabel)
                    .font(.system(size: 12))
                    .foregroundColor(.hhFaint)
                if let date = lastOrderedAt {
                    Text("Ordered \(date.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 11))
                        .foregroundColor(Self.instacartGreen)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.hhCard)
        .cornerRadius(18)
        .shadow(color: Color.hhInk.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    private var itemCountLabel: String {
        let total = list.items.count
        if total == 0 { return "Empty" }
        let done = list.checkedCount
        if done == total { return "All done ✓" }
        return "\(list.pendingCount) of \(total) remaining"
    }
}

// MARK: - List Detail View

struct ListDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(GrocerySessionStore.self) private var groceryStore
    let list: ShoppingList

    @Query private var allItems: [ListItem]
    @State private var showAddItem = false
    @State private var newItemName = ""
    @State private var showChecked = true
    @FocusState private var addItemFocused: Bool
    @State private var isInstacartLoading = false
    @State private var instacartErrorMessage: String?

    private static let instacartGreen = Color(red: 0.19, green: 0.62, blue: 0.25)

    private var pendingItems: [ListItem] {
        list.items.filter { !$0.isChecked }.sorted { $0.sortOrder < $1.sortOrder }
    }
    private var checkedItems: [ListItem] {
        list.items.filter { $0.isChecked }.sorted { $0.addedAt < $1.addedAt }
    }
    private var isGroceryEligible: Bool {
        list.listType == "grocery" || list.listType == "costco"
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.hhBg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if FeatureFlags.instacartCommerce && isGroceryEligible && list.pendingCount > 0 {
                        instacartBanner
                            .padding(.bottom, 14)
                    }
                    if list.items.isEmpty {
                        emptyListState
                    } else {
                        itemsSection
                    }
                    Spacer(minLength: 110)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }

            Button { showAddItem = true } label: {
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
        .navigationTitle(list.name)
        .hhNavTitleStyle(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !checkedItems.isEmpty {
                    Button(showChecked ? "Hide done" : "Show done") {
                        withAnimation(.spring(response: 0.3)) { showChecked.toggle() }
                    }
                    .font(.system(size: 14))
                    .foregroundColor(.hhAccent)
                }
            }
        }
        .sheet(isPresented: $showAddItem) {
            AddItemSheet(list: list)
        }
        .alert("Couldn't open Instacart", isPresented: .constant(instacartErrorMessage != nil)) {
            Button("OK") { instacartErrorMessage = nil }
        } message: {
            Text(instacartErrorMessage ?? "")
        }
    }

    // MARK: - Instacart Banner

    private var instacartBanner: some View {
        HStack(spacing: 12) {
            Text("🥕")
                .font(.system(size: 24))
                .frame(width: 42, height: 42)
                .background(Self.instacartGreen.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Shop on Instacart")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.hhInk)
                    if FeatureFlags.sandboxBannerVisible {
                        Text("SANDBOX")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Self.instacartGreen)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Self.instacartGreen.opacity(0.12))
                            .cornerRadius(4)
                    }
                }
                Text("\(list.pendingCount) item\(list.pendingCount == 1 ? "" : "s") · delivery in ~1 hr")
                    .font(.system(size: 12))
                    .foregroundColor(.hhSub)
            }

            Spacer()

            if isInstacartLoading {
                ProgressView()
                    .tint(Self.instacartGreen)
                    .frame(width: 36, height: 36)
            } else {
                Button {
                    Task { await shopOnInstacart() }
                } label: {
                    Image(systemName: "arrow.up.right.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(Self.instacartGreen)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Self.instacartGreen.opacity(0.07))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Self.instacartGreen.opacity(0.2), lineWidth: 1)
        )
        .cornerRadius(14)
    }

    // MARK: - Shop Action

    private func shopOnInstacart() async {
        guard !isInstacartLoading else { return }
        isInstacartLoading = true
        defer { isInstacartLoading = false }
        do {
            let provider = ProviderRegistry.grocery
            let groceryItems = list.items.map {
                GroceryListItem(name: $0.name, quantity: $0.quantity, isChecked: $0.isChecked)
            }
            let url = try await provider.createShoppingSession(items: groceryItems)
            groceryStore.record(list: list, provider: provider.providerName)
            openURL(url)
        } catch {
            instacartErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Items

    private var itemsSection: some View {
        VStack(spacing: 0) {
            if !pendingItems.isEmpty {
                VStack(spacing: 8) {
                    ForEach(pendingItems) { item in
                        ListItemRow(item: item, onToggle: { toggleItem(item) }, onDelete: { deleteItem(item) })
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .scale(scale: 0.85).combined(with: .opacity)
                            ))
                    }
                }
            }

            if showChecked && !checkedItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Done (\(checkedItems.count))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.hhFaint)
                        .padding(.top, pendingItems.isEmpty ? 0 : 20)
                        .padding(.bottom, 4)

                    ForEach(checkedItems) { item in
                        ListItemRow(item: item, onToggle: { toggleItem(item) }, onDelete: { deleteItem(item) })
                    }
                }

                Button {
                    withAnimation(.spring(response: 0.35)) {
                        checkedItems.forEach { modelContext.delete($0) }
                    }
                } label: {
                    Text("Clear \(checkedItems.count) done")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.hhAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.hhAccent.opacity(0.08))
                        .cornerRadius(10)
                }
                .padding(.top, 10)
            }
        }
    }

    private var emptyListState: some View {
        VStack(spacing: 14) {
            Text(list.emoji).font(.system(size: 48))
            Text("List is empty")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.hhInk)
            Text("Tap + to add your first item")
                .font(.system(size: 14))
                .foregroundColor(.hhFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Actions

    private func toggleItem(_ item: ListItem) {
        withAnimation(.spring(response: 0.3)) {
            item.isChecked.toggle()
        }
#if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
#endif
    }

    private func deleteItem(_ item: ListItem) {
        withAnimation(.spring(response: 0.3)) {
            modelContext.delete(item)
        }
    }
}

// MARK: - List Item Row

struct ListItemRow: View {
    let item: ListItem
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var dragOffset: CGFloat = 0
    private let revealWidth: CGFloat = 72

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onDelete) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: revealWidth, height: 56)
                    .background(Color.red.opacity(0.85))
                    .cornerRadius(14)
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
        HStack(spacing: 12) {
            Button(action: onToggle) {
                ZStack {
                    Circle()
                        .stroke(item.isChecked ? Color.hhGreen : Color.hhFaint, lineWidth: 2)
                        .frame(width: 26, height: 26)
                    if item.isChecked {
                        Circle().fill(Color.hhGreen).frame(width: 26, height: 26)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .animation(.spring(response: 0.25), value: item.isChecked)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 15, weight: item.isChecked ? .regular : .medium))
                    .foregroundColor(item.isChecked ? .hhFaint : .hhInk)
                    .strikethrough(item.isChecked, color: .hhFaint)
                if !item.quantity.isEmpty {
                    Text(item.quantity)
                        .font(.system(size: 12))
                        .foregroundColor(.hhFaint)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(Color.hhCard)
        .cornerRadius(14)
        .shadow(color: Color.hhInk.opacity(0.04), radius: 5, x: 0, y: 1)
    }
}

// MARK: - Add List Sheet

struct AddListSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ShoppingList.sortOrder) private var existingLists: [ShoppingList]

    @State private var name = ""
    @State private var selectedEmoji = "🛒"
    @State private var selectedType = "grocery"
    @FocusState private var nameFocused: Bool

    private let listTypes: [(String, String, String)] = [
        ("grocery",  "🛒", "Grocery"),
        ("errands",  "🏃", "Errands"),
        ("costco",   "🏪", "Costco"),
        ("custom",   "📋", "Custom"),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.hhBg.ignoresSafeArea()
                VStack(spacing: 22) {
                    HStack(spacing: 14) {
                        Text(selectedEmoji)
                            .font(.system(size: 28))
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(Color.hhAccent.opacity(0.1)))
                        Text(name.isEmpty ? "List name" : name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(name.isEmpty ? .hhFaint : .hhInk)
                        Spacer()
                    }
                    .padding(16)
                    .background(Color.hhCard)
                    .cornerRadius(16)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("LIST NAME")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.hhFaint)
                        TextField("e.g. Weekly Groceries", text: $name)
                            .font(.system(size: 16))
                            .foregroundColor(.hhInk)
                            .padding(14)
                            .background(Color.hhCard)
                            .cornerRadius(12)
                            .focused($nameFocused)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("TYPE")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.hhFaint)
                        HStack(spacing: 8) {
                            ForEach(listTypes, id: \.0) { type in
                                Button {
                                    withAnimation(.spring(response: 0.3)) {
                                        selectedType = type.0
                                        selectedEmoji = type.1
                                    }
                                } label: {
                                    VStack(spacing: 4) {
                                        Text(type.1).font(.system(size: 18))
                                        Text(type.2).font(.system(size: 10, weight: .semibold))
                                    }
                                    .foregroundColor(selectedType == type.0 ? .white : .hhSub)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(selectedType == type.0 ? Color.hhAccent : Color.hhCard)
                                    .cornerRadius(10)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Spacer()

                    Button { addList() } label: {
                        Text("Create List")
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
            .navigationTitle("New List")
            .hhNavTitleStyle(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.hhAccent)
                }
            }
            .onAppear { nameFocused = true }
        }
    }

    private func addList() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let list = ShoppingList(name: trimmed, emoji: selectedEmoji,
                                listType: selectedType, sortOrder: existingLists.count)
        modelContext.insert(list)
        dismiss()
    }
}

// MARK: - Add Item Sheet

struct AddItemSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let list: ShoppingList

    @State private var itemName = ""
    @State private var quantity = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color.hhBg.ignoresSafeArea()
                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ITEM")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.hhFaint)
                        TextField("e.g. Oat milk", text: $itemName)
                            .font(.system(size: 16))
                            .foregroundColor(.hhInk)
                            .padding(14)
                            .background(Color.hhCard)
                            .cornerRadius(12)
                            .focused($nameFocused)
                            .onSubmit { if !itemName.isEmpty { addItem() } }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("QUANTITY (OPTIONAL)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.hhFaint)
                        TextField("e.g. 2 × 1L", text: $quantity)
                            .font(.system(size: 16))
                            .foregroundColor(.hhInk)
                            .padding(14)
                            .background(Color.hhCard)
                            .cornerRadius(12)
                    }

                    Spacer()

                    Button { addItem() } label: {
                        Text("Add Item")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(itemName.isEmpty ? Color.hhFaint : Color.hhAccent)
                            .cornerRadius(14)
                    }
                    .disabled(itemName.isEmpty)
                }
                .padding(20)
            }
            .navigationTitle("Add to \(list.name)")
            .hhNavTitleStyle(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(.hhAccent)
                }
            }
            .onAppear { nameFocused = true }
        }
    }

    private func addItem() {
        let trimmed = itemName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let item = ListItem(name: trimmed, quantity: quantity.trimmingCharacters(in: .whitespaces),
                            sortOrder: list.items.count)
        modelContext.insert(item)
        list.items.append(item)
#if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
#endif
        dismiss()
    }
}

#Preview {
    NavigationStack { ListsView() }
        .modelContainer(for: [ShoppingList.self, ListItem.self], inMemory: true)
}
