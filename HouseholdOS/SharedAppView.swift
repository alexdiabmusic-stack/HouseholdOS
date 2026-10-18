import SwiftUI
import UserNotifications

enum AppTab: String, Hashable { case today, lists, tasks, money, household }

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var backend: BackendClient
    @State private var household: HouseholdStore
    @State private var reminders = ReminderService()
    @State private var selectedTab: AppTab = .today
    @State private var booted = false
    @State private var incomingInvite = ""
    @State private var showJoin = false
    @State private var notificationDelegate = HouseholdNotificationDelegate()

    init() {
        let client = BackendClient()
        _backend = State(initialValue:client)
        _household = State(initialValue:HouseholdStore(backend:client))
    }
    var body: some View {
        Group {
            if !booted { ProgressView("Opening your household…") }
            else if household.household != nil { tabs }
            else if backend.session != nil { NavigationStack { HouseholdSetupView(inviteToken:incomingInvite) } }
            else { NavigationStack { HouseholdWelcomeView() } }
        }
        .tint(.hhAccent).environment(backend).environment(household).environment(reminders)
        .task {
            notificationDelegate.onOpen = { payload in openNotification(payload) }
            UNUserNotificationCenter.current().delegate = notificationDelegate
            await backend.restore(); await household.restore(); booted = true
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-smoke-test") {
                do {
                    try household.createLocal(name:"Maple House",displayName:"Alex")
                    let groceries = try household.add(.list,fields:SharedFields(title:"Weekly groceries"))
                    var milk = SharedFields(title:"Oat milk"); milk.parentID = groceries.id; milk.quantity = "2 × 1 L"
                    try household.add(.item,fields:milk)
                    var chore = SharedFields(title:"Take out the recycling"); chore.assigneeID = household.userID; chore.dueAt = Date().addingTimeInterval(3600); chore.repeatRule = .weekly
                    try household.add(.task,fields:chore)
                    var bill = SharedFields(title:"Electricity"); bill.amountCents = 11499; bill.dueAt = Date().addingTimeInterval(86400)
                    try household.add(.bill,fields:bill)
                    if let index = ProcessInfo.processInfo.arguments.firstIndex(of:"--tab"), ProcessInfo.processInfo.arguments.indices.contains(index+1), let tab = AppTab(rawValue:ProcessInfo.processInfo.arguments[index+1]) { selectedTab = tab }
                } catch { household.error = error.localizedDescription }
            }
            #endif
        }
        .task(id:household.household?.id) {
            guard household.household != nil else { return }
            while !Task.isCancelled {
                if scenePhase == .active { await household.sync(); await updateReminders() }
                do { try await Task.sleep(for:.seconds(60)) } catch { return }
            }
        }
        .task(id:"\(household.household?.id.uuidString ?? "none")-\(scenePhase == .active)") {
            guard !household.isLocal, let active = household.household, scenePhase == .active else { return }
            while !Task.isCancelled && household.household?.id == active.id {
                do { try await backend.watchHousehold(active.id) { await household.sync() } }
                catch { if Task.isCancelled { return } }
                do { try await Task.sleep(for:.seconds(10)) } catch { return }
            }
        }
        .onChange(of:backend.session?.user.id) { _, user in
            if user != nil { Task { await household.loadMemberships() } }
        }
        .onChange(of:scenePhase) { _, phase in
            if phase == .active { Task { await household.sync(); await updateReminders() } }
        }
        .onChange(of:household.records) { _, _ in Task { await updateReminders() } }
        .onOpenURL { url in
            guard url.scheme == "householdos", url.host == "invite",
                  let token = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first(where: { $0.name == "token" })?.value else { return }
            incomingInvite = token
            if backend.session != nil { showJoin = true }
        }
        .sheet(isPresented:$showJoin) { NavigationStack { HouseholdSetupView(inviteToken:incomingInvite) } }
    }
    private var tabs: some View {
        TabView(selection:$selectedTab) {
            NavigationStack { SharedTodayView() }.tabItem { Label("Today",systemImage:"sun.max") }.tag(AppTab.today)
            NavigationStack { SharedListsView() }.tabItem { Label("Lists",systemImage:"list.bullet") }.tag(AppTab.lists)
            NavigationStack { SharedTasksView() }.tabItem { Label("Tasks",systemImage:"checkmark.circle") }.tag(AppTab.tasks)
            NavigationStack { SharedMoneyView() }.tabItem { Label("Money",systemImage:"dollarsign.circle") }.tag(AppTab.money)
            NavigationStack { SharedHouseholdView() }.tabItem { Label("Household",systemImage:"person.2") }.tag(AppTab.household)
        }
    }
    private func updateReminders() async {
        guard let active = household.household else { await reminders.clear(); return }
        await reminders.reconcile(records:household.records,userID:household.userID,timezone:active.timezone)
    }
    private func openNotification(_ payload: [AnyHashable:Any]) {
        if let raw = payload["householdID"] as? String, let id = UUID(uuidString:raw), let target = household.households.first(where: { $0.id == id }) { household.select(target) }
        selectedTab = payload["kind"] as? String == "bill" ? .money : .tasks
    }
}

final class HouseholdNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    @MainActor var onOpen: (([AnyHashable:Any]) -> Void)?
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let payload = response.notification.request.content.userInfo
        Task { @MainActor in onOpen?(payload) }
        completionHandler()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner,.sound])
    }
}
