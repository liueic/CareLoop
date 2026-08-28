import Foundation

enum FollowUpSummaryService {
    static func makeSummary(
        profile: UserProfile,
        alerts: [AlertRecord],
        adherence: AdherenceSummary,
        logs: [DailyLogEntry]
    ) -> String {
        let sections = VisitPackContentBuilder.buildSections(
            VisitPackInput(
                followUp: nil,
                profile: profile,
                medications: [],
                alerts: alerts,
                adherence: adherence,
                logs: logs,
                reports: []
            )
        )
        return sections.map { "【\($0.title)】\n\($0.body)" }.joined(separator: "\n\n")
    }
}

enum StreakService {
    static func consecutiveDays(_ entries: [DailyLogEntry], now: Date = Date(), calendar: Calendar = .current) -> Int {
        let days = Set(entries.map { calendar.startOfDay(for: $0.createdAt) })
        var cursor = calendar.startOfDay(for: now)
        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }
}

enum TodayStatus: String, Sendable {
    case stable = "稳定"
    case watch = "值得关注"
    case consult = "建议咨询医生"

    static func from(alerts: [AlertRecord]) -> TodayStatus {
        let maxTier = alerts.map(\.tier).max() ?? .l1
        switch maxTier {
        case .l5, .l4: return .consult
        case .l3, .l2: return .watch
        case .l1: return .stable
        }
    }
}
