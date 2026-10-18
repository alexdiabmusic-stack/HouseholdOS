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

#Preview {
    ContentView()
        .modelContainer(for: [HouseholdTask.self, DailyCompletion.self, ShoppingList.self, ListItem.self, MaintenanceTask.self], inMemory: true)
}
