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
    case vo2max
    case respiratoryRate
    case wristTemperatureDeviation
    case cgmTIR
    case cgmMean
    case sleepDeepPercent
    case sleepREMPercent
    case afBurden
    case hba1c
    case totalCholesterol
    case ldlCholesterol
    case hdlCholesterol
    case triglycerides
    case waistCircumference

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
        case .vo2max: "最大摄氧量"
        case .respiratoryRate: "呼吸频率"
        case .wristTemperatureDeviation: "手腕温度偏差"
        case .cgmTIR: "血糖目标范围时间"
        case .cgmMean: "平均血糖(CGM)"
        case .sleepDeepPercent: "深睡比例"
        case .sleepREMPercent: "REM比例"
        case .afBurden: "房颤负荷"
        case .hba1c: "糖化血红蛋白"
        case .totalCholesterol: "总胆固醇"
        case .ldlCholesterol: "低密度脂蛋白"
        case .hdlCholesterol: "高密度脂蛋白"
        case .triglycerides: "甘油三酯"
        case .waistCircumference: "腰围"
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
        case .vo2max: "mL/kg/min"
        case .respiratoryRate: "次/分"
        case .wristTemperatureDeviation: "°C"
        case .cgmTIR: "%"
        case .cgmMean: "mmol/L"
        case .sleepDeepPercent, .sleepREMPercent, .afBurden, .hba1c: "%"
        case .totalCholesterol, .ldlCholesterol, .hdlCholesterol, .triglycerides: "mmol/L"
        case .waistCircumference: "cm"
        }
    }

    var higherIsWorse: Bool {
        switch self {
        case .restingHeartRate, .heartRate, .bloodPressureSystolic, .bloodPressureDiastolic,
             .bloodGlucose, .cgmMean, .afBurden, .wristTemperatureDeviation,
             .hba1c, .totalCholesterol, .ldlCholesterol, .triglycerides, .waistCircumference:
            true
        case .vo2max, .cgmTIR, .sleepDeepPercent, .sleepREMPercent, .hdlCholesterol:
            false
        default:
            false
        }
    }

    var clinicalKey: String? {
        switch self {
        case .restingHeartRate: "resting_heart_rate"
        case .heartRate: "heart_rate"
        case .bloodPressureSystolic: "sbp"
        case .bloodPressureDiastolic: "dbp"
        case .bloodGlucose: "blood_glucose"
        case .oxygenSaturation: "spo2"
        case .stepCount: "steps"
        case .sleepHours: "sleep_duration"
        case .sleepDeepPercent: "deep_sleep_ratio"
        case .sleepREMPercent: "rem_sleep_ratio"
        case .bodyMass: "weight"
        case .vo2max: "vo2max"
        case .respiratoryRate: "respiratory_rate"
        case .wristTemperatureDeviation: "wrist_temp_amplitude"
        case .cgmTIR: "cgm_tir"
        case .cgmMean: "cgm_mean"
        case .afBurden: "af_burden"
        case .hba1c: "hba1c"
        case .totalCholesterol: "tc"
        case .ldlCholesterol: "ldl_c"
        case .hdlCholesterol: "hdl_c"
        case .triglycerides: "tg"
        case .waistCircumference: "waist"
        case .hrvSDNN, .activeEnergy, .workoutMinutes:
            nil
        }
    }

    var wearableReferenceNote: String? {
        switch self {
        case .restingHeartRate:
            "95% 健康成人 50–82 bpm（Quer 2020）；单周升高 >10 bpm 值得关注"
        case .oxygenSaturation:
            "Apple Watch 健康人偶发 92–94% 多为设备误差（Schröder 2023）；看趋势非单点"
        case .hrvSDNN:
            "Apple Watch 系统性低估 ~8 ms，绝对值不用于临床判断，只看个体趋势（O'Grady 2024）"
        case .sleepHours:
            "最优区间 6.5–7.5 小时（Quer 2020）；入睡 22:00–22:59 心血管风险最低"
        case .stepCount:
            "8,000–9,000 步/天为糖尿病/高血压风险下降平台（Master 2022）"
        case .vo2max:
            "Apple Watch 平均低估 ~6 mL/kg/min（Lambe 2025）；只看趋势变化"
        case .respiratoryRate:
            "健康成人 12–20 次/分；持续 >20 或 <10 值得关注"
        case .cgmTIR:
            "非糖尿病健康人 TIR(70–140 mg/dL) ≥ 96%（CGM-HYPE）"
        case .cgmMean:
            "非糖尿病健康人均值约 5.9 mmol/L（CGM-HYPE）"
        case .sleepDeepPercent:
            "PSG 实测健康成人深睡约 10–15%（Apple 2023 验证集 12.8%）"
        case .sleepREMPercent:
            "PSG 实测健康成人 REM 约 20–25%（Apple 2023 验证集 21.4%）"
        case .afBurden:
            "Apple Watch AFib 筛查敏感度 93.6%、特异度 97.0%（Apple 2023）"
        default:
            nil
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
