import Foundation
import UserNotifications

enum NotificationService {
    static func requestAccess() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func syncFollowUpReminders(from followUps: [FollowUp]) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix("careloop.followup.") }
            center.removePendingNotificationRequests(withIdentifiers: ids)
            if let next = FollowUpService.nextFollowUp(from: followUps) {
                scheduleFollowUpReminders(next)
            }
        }
    }

    static func scheduleFollowUpReminders(_ followUp: FollowUp) {
        let center = UNUserNotificationCenter.current()
        let calendar = Calendar.current
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: followUp.date) ?? followUp.date
        let triggers: [(Date, String, String)] = [
            (dayBefore, "careloop.followup.\(followUp.id.uuidString).d1", "明天有复诊安排"),
            (followUp.date, "careloop.followup.\(followUp.id.uuidString).day", "今天有复诊安排"),
        ]
        for (day, identifier, prefix) in triggers {
            guard day >= calendar.startOfDay(for: Date()) else { continue }
            var components = calendar.dateComponents([.year, .month, .day], from: day)
            components.hour = identifier.hasSuffix(".d1") ? 9 : 8
            components.minute = 0
            guard let fireDate = calendar.date(from: components), fireDate > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = prefix
            var body = followUp.department
            if !followUp.doctorName.isEmpty { body += " · \(followUp.doctorName)" }
            if !followUp.effectiveMaterials.isEmpty {
                body += "。请携带：\(FollowUpService.joinList(followUp.effectiveMaterials))"
            }
            content.body = body
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        }
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

    static func syncMedicationReminders(from medications: [Medication]) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(
            withIdentifiers: pendingIDs(prefix: "careloop.medication.")
        )
        for med in medications where med.isActive && med.confirmedByUser {
            for (index, timeText) in med.timesOfDay.enumerated() {
                let parts = timeText.split(separator: ":")
                guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { continue }
                let identifier = "careloop.medication.\(med.id.uuidString).\(index)"
                let content = UNMutableNotificationContent()
                content.title = "该吃药啦"
                var body = med.name
                if !med.dosePerTime.isEmpty { body += " · \(med.dosePerTime)" }
                content.body = body
                content.sound = .default
                var date = DateComponents()
                date.hour = hour
                date.minute = minute
                let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: true)
                center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            }
        }
    }

    static func scheduleDietReminders(forDiabetic isDiabetic: Bool) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(
            withIdentifiers: pendingIDs(prefix: "careloop.diet.")
        )
        guard isDiabetic else { return }
        let meals: [(String, Int, Int)] = [
            ("breakfast", 7, 30),
            ("lunch", 11, 30),
            ("dinner", 17, 30),
        ]
        for (meal, hour, minute) in meals {
            let identifier = "careloop.diet.\(meal)"
            let content = UNMutableNotificationContent()
            content.title = "该想想吃什么啦"
            content.body = "问问饱饱，搭配适合你的饮食～ (=^･^=)"
            content.sound = .default
            var date = DateComponents()
            date.hour = hour
            date.minute = minute
            let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: true)
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        }
    }

    private static func pendingIDs(prefix: String) -> [String] {
        var result: [String] = []
        let semaphore = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            result = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }
}
