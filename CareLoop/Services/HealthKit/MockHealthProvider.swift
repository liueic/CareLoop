import Foundation

actor MockHealthProvider: HealthDataProviding {
    let sourceLabel = "Mock 剧本"
    private let generated: [MetricType: [DailyMetricPoint]]
    private let profile: CharacteristicSnapshot

    init(referenceDate: Date = Date(), seedProfile: CharacteristicSnapshot? = nil) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: referenceDate)
        var table: [MetricType: [DailyMetricPoint]] = [:]
        for type in MetricType.allCases {
            var points: [DailyMetricPoint] = []
            for offset in (0..<30).reversed() {
                guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
                let late = offset <= 2
                let value: Double
                switch type {
                case .sleepHours:
                    value = late ? 5.05 : 7.25
                case .restingHeartRate:
                    value = late ? 76 : 61
                case .heartRate:
                    value = late ? 84 : 68
                case .stepCount:
                    value = late ? 2800 : 7800
                case .hrvSDNN:
                    value = late ? 22 : 38
                case .activeEnergy:
                    value = late ? 180 : 420
                case .bodyMass:
                    value = 68.5
                case .bloodPressureSystolic:
                    value = late ? 138 : 124
                case .bloodPressureDiastolic:
                    value = late ? 88 : 78
                case .bloodGlucose:
                    value = late ? 7.4 : 5.8
                case .oxygenSaturation:
                    value = 97
                case .workoutMinutes:
                    value = late ? 0 : 25
                }
                points.append(DailyMetricPoint(day: day, value: value, sourceName: "Mock 剧本"))
            }
            table[type] = points
        }
        generated = table
        profile = seedProfile ?? CharacteristicSnapshot(
            birthDate: cal.date(byAdding: .year, value: -58, to: today),
            biologicalSex: .female,
            bloodType: .oPos,
            heightCM: 158,
            weightKG: 68.5,
            wheelchairUse: .no
        )
    }

    func requestAuthorization() async throws {}

    func characteristics() async -> CharacteristicSnapshot { profile }

    func metric(_ type: MetricType, on day: Date) async -> HealthMetric? {
        let dayStart = Calendar.current.startOfDay(for: day)
        guard let point = generated[type]?.first(where: { Calendar.current.isDate($0.day, inSameDayAs: dayStart) }) else {
            return nil
        }
        return HealthMetric(type: type, value: point.value, date: day, sourceName: sourceLabel)
    }

    func dailySeries(_ type: MetricType, days: Int) async -> [DailyMetricPoint] {
        Array((generated[type] ?? []).suffix(days))
    }
}
