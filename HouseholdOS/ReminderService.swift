import Foundation
import Observation
import UserNotifications

@Observable @MainActor final class ReminderService {
    private(set) var permission: UNAuthorizationStatus = .notDetermined
    var error: String?
    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey:"hh.remindersEnabled") }
        set { UserDefaults.standard.set(newValue,forKey:"hh.remindersEnabled") }
    }

    func requestPermission() async {
        do {
            enabled = try await UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.badge,.sound])
            permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        } catch { self.error = error.localizedDescription }
    }

    func reconcile(records: [SharedRecord], userID: UUID, timezone: String) async {
        let center = UNUserNotificationCenter.current()
        permission = await center.notificationSettings().authorizationStatus
        let existing = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix("hh.") }
        center.removePendingNotificationRequests(withIdentifiers:existing.map(\.identifier))
        guard enabled, permission == .authorized || permission == .provisional else { return }
        var calendar = Calendar(identifier:.gregorian)
        calendar.timeZone = TimeZone(identifier:timezone) ?? .current
        let due = records.filter { !$0.deleted && !$0.isFinished && ($0.kind == .task || $0.kind == .bill) && ($0.payload.assigneeID == nil || $0.payload.assigneeID == userID) }
            .sorted { ($0.payload.dueAt ?? .distantFuture) < ($1.payload.dueAt ?? .distantFuture) }
        for record in due.prefix(60) {
            guard let date = record.payload.dueAt else { continue }
            let remindAt = calendar.date(byAdding:.day,value:-1,to:date) ?? date
            let fire = remindAt > Date() ? remindAt : date
            guard fire > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = record.payload.title
            content.body = record.kind == .bill ? "A household bill is due soon. Open the app to review it." : "Your household task is due soon."
            content.sound = .default
            content.userInfo = ["recordID":record.id.uuidString,"householdID":record.householdID.uuidString,"kind":record.kind.rawValue]
            var components = calendar.dateComponents([.year,.month,.day,.hour,.minute],from:fire)
            components.timeZone = calendar.timeZone
            do { try await center.add(UNNotificationRequest(identifier:"hh.\(record.id)",content:content,trigger:UNCalendarNotificationTrigger(dateMatching:components,repeats:false))) }
            catch { self.error = error.localizedDescription }
        }
    }

    func clear() async {
        let center = UNUserNotificationCenter.current()
        let existing = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix("hh.") }
        center.removePendingNotificationRequests(withIdentifiers:existing.map(\.identifier))
        center.removeAllDeliveredNotifications()
    }
}
