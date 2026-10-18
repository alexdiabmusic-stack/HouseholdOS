import SwiftUI
import SwiftData

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .modelContainer(for: [
                HouseholdTask.self,
                DailyCompletion.self,
                ShoppingList.self,
                ListItem.self,
                MaintenanceTask.self,
            ])
    }
}

struct ContentView: View {
    @State private var selectedTab: AppTab = .today
    @State private var financialStore = FinancialStore()
    @State private var grocerySessionStore = GrocerySessionStore()
    @State private var paymentStore = PaymentStore()
    @State private var marketplaceStore = ServiceMarketplaceStore()
    @State private var storeKitStore = StoreKitStore()
    @State private var rewardsStore = RewardsStore()

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { TodayView() }
                .tabItem { Label("Today", systemImage: "sparkles") }
                .tag(AppTab.today)
            NavigationStack { MoneyView() }
                .tabItem { Label("Money", systemImage: "dollarsign.circle") }
                .tag(AppTab.money)
            NavigationStack { ListsView() }
                .tabItem { Label("Lists", systemImage: "list.bullet") }
                .tag(AppTab.lists)
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "house") }
                .tag(AppTab.home)
            NavigationStack { YouView() }
                .tabItem { Label("You", systemImage: "person.circle") }
                .tag(AppTab.you)
        }
        .tint(.hhAccent)
        .environment(financialStore)
        .environment(grocerySessionStore)
        .environment(paymentStore)
        .environment(marketplaceStore)
        .environment(storeKitStore)
        .environment(rewardsStore)
        .task { await financialStore.load() }
        .task { grocerySessionStore.load() }
        .task { paymentStore.load() }
        .task { marketplaceStore.load() }
        .task { await storeKitStore.load() }
        .task { await rewardsStore.load() }
    }
}

enum AppTab: String, Hashable {
    case today, money, lists, home, you
}

#Preview {
    ContentView()
        .modelContainer(for: [
            HouseholdTask.self,
            DailyCompletion.self,
            ShoppingList.self,
            ListItem.self,
            MaintenanceTask.self,
        ], inMemory: true)
}
