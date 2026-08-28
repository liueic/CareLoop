import Foundation

enum MetricType: String, Codable, CaseIterable, Sendable, Identifiable {
    case stepCount
    case restingHeartRate
    case heartRate
    case hrvSDNN
    case activeEnergy
    case sleepHours
    case bodyMass
    case bloodPressureSystolic
    case bloodPressureDiastolic
    case bloodGlucose
    case oxygenSaturation
    case workoutMinutes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stepCount: "步数"
        case .restingHeartRate: "静息心率"
        case .heartRate: "心率"
        case .hrvSDNN: "心率变异性"
        case .activeEnergy: "活动能量"
        case .sleepHours: "睡眠"
        case .bodyMass: "体重"
        case .bloodPressureSystolic: "收缩压"
        case .bloodPressureDiastolic: "舒张压"
        case .bloodGlucose: "血糖"
        case .oxygenSaturation: "血氧"
        case .workoutMinutes: "运动时长"
        }
    }

    var unit: String {
        switch self {
        case .stepCount: "步"
        case .restingHeartRate, .heartRate: "次/分"
        case .hrvSDNN: "ms"
        case .activeEnergy: "kcal"
        case .sleepHours: "小时"
        case .bodyMass: "kg"
        case .bloodPressureSystolic, .bloodPressureDiastolic: "mmHg"
        case .bloodGlucose: "mmol/L"
        case .oxygenSaturation: "%"
        case .workoutMinutes: "分钟"
        }
    }

    var higherIsWorse: Bool {
        switch self {
        case .restingHeartRate, .heartRate, .bloodPressureSystolic, .bloodPressureDiastolic, .bloodGlucose:
            true
        default:
            false
        }
    }
}

struct HealthMetric: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var type: MetricType
    var value: Double
    var unit: String
    var date: Date
    var sourceName: String

    init(
        id: UUID = UUID(),
        type: MetricType,
        value: Double,
        unit: String? = nil,
        date: Date,
        sourceName: String
    ) {
        self.id = id
        self.type = type
        self.value = value
        self.unit = unit ?? type.unit
        self.date = date
        self.sourceName = sourceName
    }
}

struct DailyMetricPoint: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var day: Date
    var value: Double
    var sourceName: String

    init(id: UUID = UUID(), day: Date, value: Double, sourceName: String) {
        self.id = id
        self.day = Calendar.current.startOfDay(for: day)
        self.value = value
        self.sourceName = sourceName
    }
}

struct CharacteristicSnapshot: Codable, Hashable, Sendable {
    var birthDate: Date?
    var biologicalSex: BiologicalSex?
    var bloodType: BloodType?
    var heightCM: Double?
    var weightKG: Double?
    var wheelchairUse: WheelchairUse?
}
