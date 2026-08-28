import Foundation

enum FollowUpService {
    /// Next confirmed, incomplete follow-up on or after today.
    static func nextFollowUp(from followUps: [FollowUp], now: Date = Date()) -> FollowUp? {
        let start = Calendar.current.startOfDay(for: now)
        return followUps
            .filter { $0.confirmedByUser && !$0.isCompleted && $0.date >= start }
            .sorted { $0.date < $1.date }
            .first
    }

    static func completedFollowUps(from followUps: [FollowUp]) -> [FollowUp] {
        followUps
            .filter(\.isCompleted)
            .sorted { ($0.completedAt ?? $0.date) > ($1.completedAt ?? $1.date) }
    }

    static func daysUntil(_ date: Date, from now: Date = Date()) -> Int {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let target = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: start, to: target).day ?? 0
    }

    static func countdownText(for date: Date, now: Date = Date()) -> String {
        let days = daysUntil(date, from: now)
        switch days {
        case ..<0: return "已过期"
        case 0: return "今天"
        case 1: return "明天"
        default: return "\(days) 天后"
        }
    }

    static func countdownDays(for date: Date, now: Date = Date()) -> Int {
        max(daysUntil(date, from: now), 0)
    }

    /// 0 = 还很远，1 = 今天或已过。
    static func countdownProgress(for date: Date, windowDays: Int = 30, now: Date = Date()) -> Double {
        let days = daysUntil(date, from: now)
        if days <= 0 { return 1 }
        if days >= windowDays { return 0.05 }
        return max(0.05, 1 - Double(days) / Double(windowDays))
    }

    static func urgencyLevel(for date: Date, now: Date = Date()) -> FollowUpUrgency {
        FollowUpUrgency.from(days: daysUntil(date, from: now))
    }

    static func splitList(_ text: String) -> [String] {
        text
            .split { "、,，;；\n".contains($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func joinList(_ items: [String]) -> String {
        items.joined(separator: "、")
    }
}
