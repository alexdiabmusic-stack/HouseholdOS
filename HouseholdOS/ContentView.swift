import SwiftUI
import SwiftData
import Playgrounds

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [HouseholdTask.self, DailyCompletion.self])
    }
}

struct ContentView: View {
    var body: some View {
        StreakDashboardView()
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [HouseholdTask.self, DailyCompletion.self], inMemory: true)
}

#Playground {
    _ = 1 + 2
}
