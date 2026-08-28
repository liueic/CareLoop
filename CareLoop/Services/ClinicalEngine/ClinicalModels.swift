import Foundation

enum ClinicalRiskLevel: String, Codable, Sendable, CaseIterable {
    case normal
    case lowElevated = "low_elevated"
    case medium
    case high
    case urgent

    var rank: Int {
        switch self {
        case .normal: 0
        case .lowElevated: 1
        case .medium: 2
        case .high: 3
        case .urgent: 4
        }
    }

    var displayName: String {
        switch self {
        case .normal: "正常"
        case .lowElevated: "偏高"
        case .medium: "中等风险"
        case .high: "高风险"
        case .urgent: "紧急"
        }
    }

    var alertTier: AlertTier {
        switch self {
        case .urgent: .l5
        case .high: .l4
        case .medium: .l3
        case .lowElevated: .l2
        case .normal: .l1
        }
    }

    static func max(_ lhs: ClinicalRiskLevel, _ rhs: ClinicalRiskLevel) -> ClinicalRiskLevel {
        lhs.rank >= rhs.rank ? lhs : rhs
    }
}

struct ClinicalEvidence: Equatable, Sendable {
    var guideline: String
    var section: String
    var quote: String?
}

struct ClinicalTriggeredRule: Equatable, Sendable {
    var ruleID: String
    var riskLevel: ClinicalRiskLevel
    var evidence: [ClinicalEvidence]
    var confidence: String
    var data: [String: ClinicalJSON]
    var tags: [String]
}

struct ClinicalAdviceItem: Equatable, Sendable {
    var id: String
    var text: String
}

struct ClinicalDomainResult: Equatable, Sendable {
    var domain: String
    var riskLevel: ClinicalRiskLevel
    var summary: String
    var triggeredRules: [ClinicalTriggeredRule]
    var advice: [ClinicalAdviceItem]
}

struct ClinicalQualityIssue: Equatable, Sendable {
    var metric: String
    var value: Double
    var reason: String
}

struct ClinicalEvaluation: Equatable, Sendable {
    var evaluationID: String
    var rulesetVersion: String
    var rulesetSHA256: String
    var inputDigest: String
    var evaluatedAt: Date
    var domains: [String: ClinicalDomainResult]
    var dataQuality: [ClinicalQualityIssue]
    var disclaimer: String
}

struct ClinicalHistoryPoint: Equatable, Sendable {
    var metric: String
    var value: Double
    var unit: String
    var timestamp: Date
    var deviceID: String
    var tags: [String: String]
}

struct ClinicalUserProfile: Equatable, Sendable {
    var age: Int?
    var sex: String
    var smoking: Bool

    init(age: Int? = nil, sex: String = "male", smoking: Bool = false) {
        self.age = age
        self.sex = sex
        self.smoking = smoking
    }
}

struct ClinicalMeasurement: Equatable, Sendable {
    var metric: String
    var value: Double
    var unit: String
    var timestamp: Date
    var deviceID: String
    var tags: [String: String]
}
