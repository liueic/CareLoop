import Foundation

/// GitHub 风格记录热力图的数据聚合，纯函数可单测。
enum ActivityHeatmap {
    struct Week: Identifiable, Hashable, Sendable {
        var id: Date { start }
        var start: Date
        /// 固定 7 格，周一到周日；未来日期为 nil（渲染为空白）。
        var days: [Date?]
    }

    /// 按天聚合计数（手帐条目 + 服药打卡）。
    static func counts(dates: [Date], calendar: Calendar = .current) -> [Date: Int] {
        var result: [Date: Int] = [:]
        for date in dates {
            result[calendar.startOfDay(for: date), default: 0] += 1
        }
        return result
    }

    /// 组装最近 N 周（含本周）的网格，列 = 周，行 = 周一…周日。
    static func weeks(
        weeksBack: Int = 11,
        from now: Date = Date(),
        calendar input: Calendar = .current
    ) -> [Week] {
        var calendar = input
        calendar.firstWeekday = 2 // 周一
        let today = calendar.startOfDay(for: now)
        guard let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start else {
            return []
        }
        return (0...max(0, weeksBack)).reversed().map { offset in
            let weekStart = calendar.date(byAdding: .weekOfYear, value: -offset, to: thisWeekStart) ?? thisWeekStart
            let days: [Date?] = (0..<7).map { i in
                guard let day = calendar.date(byAdding: .day, value: i, to: weekStart) else { return nil }
                return day <= today ? day : nil
            }
            return Week(start: weekStart, days: days)
        }
    }

    /// 记录条数 → 0…4 色阶。
    static func level(for count: Int) -> Int {
        switch count {
        case 0: return 0
        case 1: return 1
        case 2: return 2
        case 3...4: return 3
        default: return 4
        }
    }
}
