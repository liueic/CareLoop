import Foundation

struct BaselineResult: Equatable, Sendable {
    var metricType: MetricType
    var windowDays: Int
    var mean: Double
    var stdDev: Double
    var today: Double?
    var zScore: Double?
    var deviation: Bool
    var persistent: Bool
    var recentZScores: [Double]
}

enum BaselineEngine: Sendable {
    static let defaultWindow = 14
    static let deviationZ = 1.5
    static let strongZ = 2.0
    static let persistDays = 3

    static func evaluate(
        type: MetricType,
        series: [DailyMetricPoint],
        windowDays: Int = defaultWindow,
        calendar: Calendar = .current
    ) -> BaselineResult {
        let sorted = series.sorted { $0.day < $1.day }
        guard sorted.count >= 3 else {
            let mean = average(sorted.map(\.value))
            return BaselineResult(
                metricType: type,
                windowDays: windowDays,
                mean: mean,
                stdDev: 0,
                today: sorted.last?.value,
                zScore: nil,
                deviation: false,
                persistent: false,
                recentZScores: []
            )
        }

        let window = Array(sorted.suffix(windowDays))
        let history = window.dropLast()
        let values = history.map(\.value)
        let mean = average(values)
        let std = standardDeviation(values, mean: mean)
        let today = window.last?.value
        let zScores: [Double] = window.map { point in
            z(point.value, mean: mean, std: std)
        }
        let todayZ = zScores.last
        let deviation = abs(todayZ ?? 0) >= deviationZ
        let lastThree = zScores.suffix(persistDays)
        let persistent = (abs(todayZ ?? 0) >= strongZ)
            || (lastThree.count >= persistDays && lastThree.allSatisfy { abs($0) >= deviationZ })

        return BaselineResult(
            metricType: type,
            windowDays: windowDays,
            mean: mean,
            stdDev: std,
            today: today,
            zScore: todayZ,
            deviation: deviation,
            persistent: persistent,
            recentZScores: Array(zScores.suffix(7))
        )
    }

    static func z(_ value: Double, mean: Double, std: Double) -> Double {
        guard std > 0.0001 else { return 0 }
        return (value - mean) / std
    }

    static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    static func standardDeviation(_ values: [Double], mean: Double) -> Double {
        guard values.count > 1 else { return 0 }
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count - 1)
        return sqrt(variance)
    }
}
