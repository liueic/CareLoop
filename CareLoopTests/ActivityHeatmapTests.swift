import Foundation
@testable import CareLoop
import Testing

struct ActivityHeatmapTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        return cal
    }

    @Test func countsAggregateByDay() {
        let cal = calendar
        let today = cal.startOfDay(for: Date())
        let morning = cal.date(byAdding: .hour, value: 8, to: today)!
        let evening = cal.date(byAdding: .hour, value: 20, to: today)!
        let counts = ActivityHeatmap.counts(dates: [morning, evening], calendar: cal)
        #expect(counts[today] == 2)
    }

    @Test func emptyInputProducesEmptyCounts() {
        #expect(ActivityHeatmap.counts(dates: []).isEmpty)
    }

    @Test func levelsMapCountsToFiveSteps() {
        #expect(ActivityHeatmap.level(for: 0) == 0)
        #expect(ActivityHeatmap.level(for: 1) == 1)
        #expect(ActivityHeatmap.level(for: 2) == 2)
        #expect(ActivityHeatmap.level(for: 3) == 3)
        #expect(ActivityHeatmap.level(for: 4) == 3)
        #expect(ActivityHeatmap.level(for: 9) == 4)
    }

    @Test func weeksGridShapeAndTodayBoundary() {
        let cal = calendar
        let now = Date()
        let weeks = ActivityHeatmap.weeks(weeksBack: 11, from: now, calendar: cal)
        #expect(weeks.count == 12)
        for week in weeks {
            #expect(week.days.count == 7)
        }
        let today = cal.startOfDay(for: now)
        let lastWeek = weeks.last!
        // 本周：今天之前（含）都有日期，之后为 nil
        for day in lastWeek.days {
            if let day {
                #expect(day <= today)
            }
        }
        #expect(lastWeek.days.contains(today))
        // 最早的周没有 nil（12 周窗口内过去的日期都是完整的）
        #expect(weeks.first!.days.allSatisfy { $0 != nil })
        // 周一开头
        #expect(cal.component(.weekday, from: weeks.first!.start) == 2)
    }
}
