import Foundation

enum FollowUpSummaryService {
    static func makeSummary(
        profile: UserProfile,
        alerts: [AlertRecord],
        adherence: AdherenceSummary,
        logs: [DailyLogEntry]
    ) -> String {
        let conditions = profile.conditions.isEmpty ? "未填写" : profile.conditions.joined(separator: "、")
        let alertText = alerts.prefix(3).map { "\($0.tier.rawValue) \($0.title)" }.joined(separator: "；")
        let logCount = logs.count
        return """
        复诊前健康摘要（非诊断）
        病种画像：\(conditions)
        近7日服药打卡：\(adherence.percentText)
        近期提示：\(alertText.isEmpty ? "暂无" : alertText)
        手帐条数：\(logCount)
        \(CareLoopCopy.medicalDisclaimer)
        """
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
