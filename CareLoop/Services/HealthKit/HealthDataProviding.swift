import Foundation

protocol HealthDataProviding: Sendable {
    var sourceLabel: String { get }
    func requestAuthorization() async throws
    func characteristics() async -> CharacteristicSnapshot
    func metric(_ type: MetricType, on day: Date) async -> HealthMetric?
    func dailySeries(_ type: MetricType, days: Int) async -> [DailyMetricPoint]
    func watermarkSnapshot(at date: Date) async -> WatermarkSnapshot
}

extension HealthDataProviding {
    func watermarkSnapshot(at date: Date) async -> WatermarkSnapshot {
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)
        let yesterday = cal.date(byAdding: .day, value: -1, to: day) ?? day
        async let sleep = metric(.sleepHours, on: yesterday)
        async let rhr = metric(.restingHeartRate, on: day)
        async let hr = metric(.heartRate, on: day)
        async let steps = metric(.stepCount, on: day)
        async let sys = metric(.bloodPressureSystolic, on: day)
        async let dia = metric(.bloodPressureDiastolic, on: day)
        async let glu = metric(.bloodGlucose, on: day)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEEE"
        return WatermarkSnapshot(
            capturedAt: date,
            weekday: formatter.string(from: date),
            sleepHours: await sleep?.value,
            restingHeartRate: await rhr?.value,
            currentHeartRate: await hr?.value,
            steps: await steps?.value,
            bloodPressureSystolic: await sys?.value,
            bloodPressureDiastolic: await dia?.value,
            bloodGlucose: await glu?.value,
            sourceName: sourceLabel,
            weatherText: nil,
            locationText: nil
        )
    }
}
