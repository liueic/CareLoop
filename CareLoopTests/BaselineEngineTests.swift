import Foundation
@testable import CareLoop
import Testing

struct BaselineEngineTests {
    @Test func zScoreAndPersistentWindow() {
        var series: [DailyMetricPoint] = []
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        for i in (0..<14).reversed() {
            let day = cal.date(byAdding: .day, value: -i, to: today)!
            let value: Double = i <= 2 ? 78 : 60
            series.append(DailyMetricPoint(day: day, value: value, sourceName: "test"))
        }
        let result = BaselineEngine.evaluate(type: .restingHeartRate, series: series)
        #expect(result.mean > 50 && result.mean < 70)
        #expect(result.zScore ?? 0 > 1.5)
        #expect(result.persistent)
    }

    @Test func shortSeriesDoesNotCrash() {
        let result = BaselineEngine.evaluate(
            type: .stepCount,
            series: [DailyMetricPoint(day: Date(), value: 1000, sourceName: "t")]
        )
        #expect(result.deviation == false)
        #expect(result.stdDev == 0)
    }

    @Test func boundaryZ() {
        let z = BaselineEngine.z(70, mean: 60, std: 5)
        #expect(abs(z - 2.0) < 0.01)
    }
}
