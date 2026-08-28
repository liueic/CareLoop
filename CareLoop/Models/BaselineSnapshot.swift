import Foundation
import SwiftData

@Model
final class BaselineSnapshot {
    var id: UUID
    var metricTypeRaw: String
    var windowDays: Int
    var mean: Double
    var stdDev: Double
    var computedAt: Date

    init(metricType: MetricType, windowDays: Int, mean: Double, stdDev: Double, computedAt: Date = Date()) {
        self.id = UUID()
        self.metricTypeRaw = metricType.rawValue
        self.windowDays = windowDays
        self.mean = mean
        self.stdDev = stdDev
        self.computedAt = computedAt
    }

    var metricType: MetricType {
        get { MetricType(rawValue: metricTypeRaw) ?? .restingHeartRate }
        set { metricTypeRaw = newValue.rawValue }
    }
}
