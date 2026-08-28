import Foundation
@testable import CareLoop
import Testing

struct AlertEngineTests {
    private func profile(_ conditions: [String] = ["高血压"]) -> ProfileTags {
        ProfileTags(
            conditions: conditions,
            foodAllergies: [],
            injuries: [],
            doctorRestrictions: [],
            cuisineLikes: [],
            cuisineDislikes: [],
            spiciness: "none",
            dislikedIngredients: [],
            dietGoals: ["控盐"],
            preferredSports: [],
            avoidedSports: [],
            facilities: [],
            intensityCeiling: "低",
            region: "广东",
            ageDecade: "50s"
        )
    }

    @Test func redFlagIsL5() {
        let rules = GuidelineRules.load()
        let drafts = AlertEngine.evaluate(
            profile: profile(),
            baselines: [],
            todayMetrics: [],
            recentSymptoms: [SymptomEntry(name: "胸痛", severity: .severe)],
            logText: [],
            highSugarEvent: false,
            rules: rules
        )
        #expect(drafts.contains { $0.tier == .l5 })
        #expect(drafts.contains { $0.suggestedAction.contains("急救") || $0.suggestedAction.contains("急诊") })
    }

    @Test func singleDeviationIsL2() {
        let baseline = BaselineResult(
            metricType: .restingHeartRate,
            windowDays: 14,
            mean: 60,
            stdDev: 4,
            today: 67,
            zScore: 1.75,
            deviation: true,
            persistent: false,
            recentZScores: [0.2, 1.75]
        )
        let drafts = AlertEngine.evaluate(
            profile: profile(),
            baselines: [baseline],
            todayMetrics: [],
            recentSymptoms: [],
            logText: [],
            highSugarEvent: false,
            rules: GuidelineRules.load()
        )
        #expect(drafts.contains { $0.tier == .l2 && $0.ruleIDs.contains("ALG-L2-Z") })
    }

    @Test func multiMetricAndGuideline() {
        func persist(_ type: MetricType, today: Double, mean: Double) -> BaselineResult {
            BaselineResult(
                metricType: type,
                windowDays: 14,
                mean: mean,
                stdDev: 1,
                today: today,
                zScore: 2.2,
                deviation: true,
                persistent: true,
                recentZScores: [1.6, 1.7, 2.2]
            )
        }
        let drafts = AlertEngine.evaluate(
            profile: profile(["高血压"]),
            baselines: [
                persist(.sleepHours, today: 5, mean: 7.2),
                persist(.restingHeartRate, today: 78, mean: 61),
                persist(.stepCount, today: 2000, mean: 8000),
            ],
            todayMetrics: [
                HealthMetric(type: .bloodPressureSystolic, value: 150, date: Date(), sourceName: "Mock"),
            ],
            recentSymptoms: [SymptomEntry(name: "乏力", severity: .moderate)],
            logText: ["今天很累"],
            highSugarEvent: false,
            rules: GuidelineRules.load()
        )
        #expect(drafts.contains { $0.ruleIDs.contains("ALG-L3-MULTI") })
        #expect(drafts.contains { $0.tier == .l4 })
    }

    @Test func sugarEventForDiabetesIsL1() {
        let drafts = AlertEngine.evaluate(
            profile: profile(["糖尿病"]),
            baselines: [],
            todayMetrics: [],
            recentSymptoms: [],
            logText: ["喝了奶茶"],
            highSugarEvent: true,
            rules: GuidelineRules.load()
        )
        #expect(drafts.contains { $0.tier == .l1 && $0.ruleIDs.contains("ALG-L1-SUGAR") })
    }
}
