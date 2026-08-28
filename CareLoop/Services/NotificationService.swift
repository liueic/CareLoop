import Foundation
import UserNotifications

enum NotificationService {
    static func requestAccess() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func scheduleDailyJournalReminder(hour: Int, minute: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["careloop.journal.daily"])
        let content = UNMutableNotificationContent()
        content.title = "今天过得怎么样"
        content.body = "有空的话，随手记一条就好。不必给自己压力。"
        content.sound = .default
        var date = DateComponents()
        date.hour = hour
        date.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: true)
        let request = UNNotificationRequest(identifier: "careloop.journal.daily", content: content, trigger: trigger)
        center.add(request)
    }
}
