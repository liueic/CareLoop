import Foundation
import SwiftData

@Model
final class AlertRecord {
    var id: UUID
    var createdAt: Date
    var tierRaw: String
    var title: String
    var whatChanged: String
    var baselineDelta: String
    var whyItMatters: String
    var suggestedAction: String
    var evidence: String
    var relatedMetricTypes: [String]
    var acknowledged: Bool
    var ruleIDs: [String]

    init(
        tier: AlertTier,
        title: String,
        whatChanged: String,
        baselineDelta: String,
        whyItMatters: String,
        suggestedAction: String,
        evidence: String,
        relatedMetricTypes: [MetricType],
        ruleIDs: [String]
    ) {
        self.id = UUID()
        self.createdAt = Date()
        self.tierRaw = tier.rawValue
        self.title = title
        self.whatChanged = whatChanged
        self.baselineDelta = baselineDelta
        self.whyItMatters = whyItMatters
        self.suggestedAction = suggestedAction
        self.evidence = evidence
        self.relatedMetricTypes = relatedMetricTypes.map(\.rawValue)
        self.acknowledged = false
        self.ruleIDs = ruleIDs
    }

    var tier: AlertTier {
        get { AlertTier(rawValue: tierRaw) ?? .l1 }
        set { tierRaw = newValue.rawValue }
    }
}
