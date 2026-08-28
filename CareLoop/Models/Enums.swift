import Foundation

enum CareLoopCopy {
    static let medicalDisclaimer = "本应用不提供疾病诊断，不构成医疗建议。"
    static let aiAdviceDisclaimer = "AI 建议，仅供参考"
    static let notADiagnosis = "以下内容用于帮助你观察自身变化，不能替代医生判断。"
}

enum ChronicCondition: String, Codable, CaseIterable, Identifiable, Sendable {
    case hypertension = "高血压"
    case diabetes = "糖尿病"
    case metabolicSyndrome = "代谢综合征"
    case atrialFibrillation = "房颤"
    case heartDisease = "心脏病"

    var id: String { rawValue }

    var defaultDietGoals: [DietGoal] {
        switch self {
        case .hypertension: [.saltControl]
        case .diabetes, .metabolicSyndrome: [.sugarControl]
        case .atrialFibrillation, .heartDisease: [.saltControl]
        }
    }

    var intensityCeiling: IntensityLevel {
        switch self {
        case .atrialFibrillation, .heartDisease: .low
        case .hypertension, .diabetes, .metabolicSyndrome: .medium
        }
    }
}

enum IntensityLevel: String, Codable, CaseIterable, Sendable, Comparable {
    case low = "低"
    case medium = "中"
    case high = "高"

    var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    static func < (lhs: IntensityLevel, rhs: IntensityLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    static func fromMET(_ met: Double) -> IntensityLevel {
        if met < 3 { return .low }
        if met <= 6 { return .medium }
        return .high
    }
}

enum Spiciness: String, Codable, CaseIterable, Sendable {
    case none = "不辣"
    case mild = "微辣"
    case medium = "正常"
    case hot = "重辣"

    var jsonValue: String {
        switch self {
        case .none: "none"
        case .mild: "mild"
        case .medium: "medium"
        case .hot: "hot"
        }
    }

    init(jsonValue: String) {
        switch jsonValue {
        case "none": self = .none
        case "mild": self = .mild
        case "medium": self = .medium
        case "hot": self = .hot
        default: self = .none
        }
    }

    var rank: Int {
        switch self {
        case .none: 0
        case .mild: 1
        case .medium: 2
        case .hot: 3
        }
    }
}

enum DietGoal: String, Codable, CaseIterable, Sendable {
    case saltControl = "控盐"
    case sugarControl = "控糖"
    case weightLoss = "减重"
    case bloodPressure = "血压管理"
    case generalWellness = "一般保养"
}

enum BiologicalSex: String, Codable, CaseIterable, Sendable {
    case female = "女"
    case male = "男"
    case other = "其他"
    case unspecified = "不愿填写"
}

enum BloodType: String, Codable, CaseIterable, Sendable {
    case aPos = "A+"
    case aNeg = "A-"
    case bPos = "B+"
    case bNeg = "B-"
    case abPos = "AB+"
    case abNeg = "AB-"
    case oPos = "O+"
    case oNeg = "O-"
    case unknown = "未知"
}

enum WheelchairUse: String, Codable, CaseIterable, Sendable {
    case no = "否"
    case yes = "是"
    case unspecified = "未说明"
}

enum CookFrequency: String, Codable, CaseIterable, Sendable {
    case almostNever = "几乎不做饭"
    case fewTimesWeek = "每周几次"
    case daily = "几乎每天"
}

enum ExerciseFrequency: String, Codable, CaseIterable, Sendable {
    case rare = "很少"
    case weekly = "每周1-2次"
    case regular = "每周3次以上"
    case daily = "几乎每天"
}

enum TimePreference: String, Codable, CaseIterable, Sendable {
    case morning = "早晨"
    case noon = "中午"
    case evening = "傍晚"
    case flexible = "不固定"
}

enum LogKind: String, Codable, CaseIterable, Sendable {
    case photo
    case voice
    case text
    case quickTag
    case symptom
    case medicalDoc
}

enum ConfirmationState: String, Codable, CaseIterable, Sendable {
    case pendingAI
    case confirmed
    case edited
    case skipped
}

enum LogTag: String, Codable, CaseIterable, Sendable, Identifiable {
    case diet = "饮食"
    case exercise = "运动"
    case sleep = "睡眠"
    case mood = "情绪"
    case alcohol = "饮酒"
    case caffeine = "咖啡因"
    case symptom = "症状"

    var id: String { rawValue }
}

enum SymptomSeverity: String, Codable, CaseIterable, Sendable {
    case mild = "轻"
    case moderate = "中"
    case severe = "重"
}

enum MedicationSource: String, Codable, Sendable {
    case manual = "手动"
    case prescriptionOCR = "处方识别"
    case medicalDocOCR = "病历识别"
}

enum IntakeStatus: String, Codable, CaseIterable, Sendable {
    case scheduled
    case taken
    case missed
    case skipped
}

enum FollowUpMode: String, Codable, Sendable {
    case doctorOrdered
    case smartSuggested
}

enum AlertTier: String, Codable, Comparable, CaseIterable, Sendable {
    case l1 = "L1"
    case l2 = "L2"
    case l3 = "L3"
    case l4 = "L4"
    case l5 = "L5"

    var rank: Int {
        switch self {
        case .l1: 1
        case .l2: 2
        case .l3: 3
        case .l4: 4
        case .l5: 5
        }
    }

    static func < (lhs: AlertTier, rhs: AlertTier) -> Bool {
        lhs.rank < rhs.rank
    }

    var displayTitle: String {
        switch self {
        case .l1: "一般健康建议"
        case .l2: "值得观察"
        case .l3: "持续异常"
        case .l4: "建议咨询医生"
        case .l5: "红旗症状，请尽快就医"
        }
    }
}

enum ProviderHealthStatus: String, Codable, Sendable {
    case unknown
    case ok
    case degraded
    case down
}

enum CatalogSource: String, Codable, Sendable {
    case bundled
    case synced
    case manual
    case discovered
}

enum MealType: String, Codable, CaseIterable, Sendable {
    case breakfast = "早餐"
    case lunch = "午餐"
    case dinner = "晚餐"
    case snack = "加餐"
}

struct SymptomEntry: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var bodyPart: String?
    var severity: SymptomSeverity
    var durationText: String?

    init(
        id: UUID = UUID(),
        name: String,
        bodyPart: String? = nil,
        severity: SymptomSeverity,
        durationText: String? = nil
    ) {
        self.id = id
        self.name = name
        self.bodyPart = bodyPart
        self.severity = severity
        self.durationText = durationText
    }
}

struct DailyStructuredFields: Codable, Hashable, Sendable {
    var mealType: MealType?
    var exerciseType: String?
    var exerciseIntensity: IntensityLevel?
    var recognizedFoodLabel: String?
    var recognizedExplanation: String?
    var medicalDoc: MedicalDocResult?
}

struct MedicalDocResult: Codable, Hashable, Sendable {
    var docType: String
    var title: String?
    var takenAt: String?
    var diagnoses: [String]
    var labValues: [LabValueItem]
    var medications: [ExtractedMedication]
    var recommendations: [String]
    var followUpHint: String?
    var followUpDate: String?
    var followUpDepartment: String?
    var summary: String
}

struct LabValueItem: Codable, Hashable, Sendable {
    var name: String
    var value: String
    var unit: String?
    var reference: String?
    var flag: String?
}

struct ExtractedMedication: Codable, Hashable, Sendable {
    var name: String
    var dose: String?
    var frequency: String?
    var timesOfDay: [String]?
    var frequencyPerDay: Int?
    var cautions: String?
}
