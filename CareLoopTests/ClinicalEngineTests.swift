import Foundation
@testable import CareLoop
import Testing

struct ClinicalEngineTests {
    private static let registry: ClinicalRulesetRegistry = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CareLoop/Resources/ClinicalRules")
        return ClinicalRulesetRegistry.load(fromRoot: root)
    }()

    @Test func knowledgeBaseLoadsTwentyRules() {
        let rules = Self.registry.ruleset().rules
        #expect(rules.count == 20)
        #expect(rules.contains { $0.id == "HTN-SP-001" })
        #expect(rules.contains { $0.id == "DIA-SP-001" })
        #expect(rules.contains { $0.id == "LIP-SP-001" })
        #expect(rules.contains { $0.id == "CMP-MS-001" })
    }

    @Test func goldenCasesMatchExpectedRiskLevels() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/clinical_golden_cases.json")
        let data = try Data(contentsOf: url)
        let cases = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]

        for testCase in cases {
            let id = testCase["id"] as? String ?? "?"
            let input = testCase["input"] as? [String: Any] ?? [:]
            let rawMeasurements = input["measurements"] as? [String: Any] ?? [:]
            var measurements: [String: Double] = [:]
            for (key, value) in rawMeasurements {
                if let number = value as? Double {
                    measurements[key] = number
                } else if let number = value as? Int {
                    measurements[key] = Double(number)
                } else if let number = value as? NSNumber {
                    measurements[key] = number.doubleValue
                }
            }
            let result = ClinicalEngine.evaluatePoint(
                measurements: measurements,
                registry: Self.registry
            )
            let expected = testCase["expected"] as? [String: Any] ?? [:]
            if let domains = expected["domains"] as? [String: [String: String]] {
                for (domain, payload) in domains {
                    let expectedRisk = payload["risk_level"] ?? ""
                    let actual = result.domains[domain]?.riskLevel.rawValue
                    #expect(actual == expectedRisk, "\(id) domain \(domain): expected \(expectedRisk), got \(String(describing: actual))")
                }
            }
            if let quality = expected["data_quality"] as? [[String: Any]] {
                for issue in quality {
                    let metric = issue["metric"] as? String ?? ""
                    let reason = issue["reason"] as? String ?? ""
                    #expect(
                        result.dataQuality.contains { $0.metric == metric && $0.reason == reason },
                        "\(id) missing quality issue \(metric) \(reason)"
                    )
                }
            }
        }
    }

    @Test func demoTodayMatchesFullPipeline() {
        let measurements: [String: Double] = [
            "sbp": 138,
            "dbp": 88,
            "blood_glucose": 7.4,
            "resting_heart_rate": 76,
            "heart_rate": 84,
            "steps": 2800,
            "sleep_duration": 5.1,
            "spo2": 97,
            "weight": 72,
            "waist": 88,
        ]
        let result = ClinicalEngine.evaluateFull(
            measurements: measurements,
            profile: ClinicalUserProfile(age: 58, sex: "female"),
            registry: Self.registry
        )
        #expect(result.domains["sbp"]?.riskLevel == .medium)
        #expect(result.domains["sbp"]?.triggeredRules.first?.ruleID == "HTN-SP-001")
        #expect(result.domains["blood_glucose"]?.riskLevel == .high)
        #expect(result.domains["htn_diabetes_escalation"]?.riskLevel == .high)
        #expect(result.domains["ascvd_risk"]?.riskLevel == .medium)
        #expect(result.domains["metabolic_syndrome"]?.riskLevel == .medium)
        #expect(result.disclaimer.contains("不构成医学诊断"))
    }

    @Test func hypotensionIsNotMaskedByHigherPriorityDefault() {
        let result = ClinicalEngine.evaluatePoint(
            measurements: ["sbp": 85, "dbp": 55],
            registry: Self.registry
        )
        #expect(result.domains["sbp"]?.riskLevel == .medium)
        #expect(result.domains["sbp"]?.triggeredRules.first?.ruleID == "HTN-SP-004")
    }
}
