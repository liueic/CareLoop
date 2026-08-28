import CryptoKit
import Foundation

enum ClinicalEngine {
    static let registry: ClinicalRulesetRegistry = .loadBundled()

    static func evaluatePoint(
        measurements: [String: Double],
        version: String? = nil,
        registry: ClinicalRulesetRegistry = registry
    ) -> ClinicalEvaluation {
        let ruleset = registry.ruleset(version)
        let (domains, quality) = runSinglePoint(measurements, ruleset: ruleset, registry: registry)
        return makeResult(
            measurementsDigest: measurements,
            extra: nil,
            ruleset: ruleset,
            registry: registry,
            version: version,
            domains: domains,
            quality: quality
        )
    }

    static func evaluateTrendHistory(
        history: [ClinicalHistoryPoint],
        version: String? = nil,
        now: Date = Date(),
        registry: ClinicalRulesetRegistry = registry
    ) -> ClinicalEvaluation {
        let ruleset = registry.ruleset(version)
        let (domains, quality) = runTrend(history, ruleset: ruleset, registry: registry, now: now)
        let digestPayload = history.map {
            "\($0.metric):\($0.value):\($0.timestamp.timeIntervalSince1970)"
        }.sorted().joined()
        return makeResult(
            measurementsDigest: [:],
            extra: digestPayload,
            ruleset: ruleset,
            registry: registry,
            version: version,
            domains: domains,
            quality: quality
        )
    }

    static func evaluateFull(
        measurements: [String: Double],
        profile: ClinicalUserProfile? = nil,
        history: [ClinicalHistoryPoint]? = nil,
        version: String? = nil,
        now: Date = Date(),
        registry: ClinicalRulesetRegistry = registry
    ) -> ClinicalEvaluation {
        let ruleset = registry.ruleset(version)
        var quality: [ClinicalQualityIssue] = []
        let (spDomains, spQuality) = runSinglePoint(measurements, ruleset: ruleset, registry: registry)
        quality.append(contentsOf: spQuality)

        var merged = spDomains
        if let history, !history.isEmpty {
            let (trendDomains, trendQuality) = runTrend(history, ruleset: ruleset, registry: registry, now: now)
            quality.append(contentsOf: trendQuality)
            merged.merge(trendDomains) { _, new in new }
        }

        let composite = ClinicalEvaluators.runComposite(
            measurements: measurements,
            domains: merged,
            profile: profile,
            ruleset: ruleset,
            registry: registry
        )
        merged.merge(composite) { _, new in new }

        return makeResult(
            measurementsDigest: measurements,
            extra: profile.map { "age=\($0.age ?? -1),sex=\($0.sex)" },
            ruleset: ruleset,
            registry: registry,
            version: version,
            domains: merged,
            quality: quality
        )
    }

    static func metricTypes(forDomain domain: String) -> [MetricType] {
        let direct = MetricType.allCases.filter { $0.clinicalKey == domain }
        if !direct.isEmpty { return direct }
        switch domain {
        case "metabolic_syndrome":
            return [.waistCircumference, .triglycerides, .hdlCholesterol, .bloodPressureSystolic, .bloodGlucose]
        case "ascvd_risk":
            return [.ldlCholesterol, .totalCholesterol, .bloodPressureSystolic, .bloodGlucose]
        case "htn_diabetes_escalation":
            return [.bloodPressureSystolic, .bloodGlucose]
        case "osa_screening":
            return [.oxygenSaturation, .bloodPressureSystolic]
        case "extreme_ldl_hypertension":
            return [.ldlCholesterol, .bloodPressureSystolic]
        default:
            return []
        }
    }

    // MARK: - Pipeline internals

    private static func runSinglePoint(
        _ measurements: [String: Double],
        ruleset: ClinicalRuleset,
        registry: ClinicalRulesetRegistry
    ) -> ([String: ClinicalDomainResult], [ClinicalQualityIssue]) {
        var quality: [ClinicalQualityIssue] = []
        for (metric, value) in measurements {
            if !registry.isPlausible(metric: metric, value: value) {
                quality.append(ClinicalQualityIssue(metric: metric, value: value, reason: "out_of_range"))
            }
        }

        var grouped: [String: [ClinicalRule]] = [:]
        for rule in ruleset.rules where rule.type == "single_point" && rule.enabled {
            let domain = rule.required.first ?? "unknown"
            grouped[domain, default: []].append(rule)
        }

        var domains: [String: ClinicalDomainResult] = [:]
        for (domain, rules) in grouped {
            guard let hit = selectBestSinglePoint(rules: rules, measurements: measurements) else { continue }
            guard let rule = rules.first(where: { $0.id == hit.ruleID }) else { continue }
            domains[domain] = makeDomain(
                domain: domain,
                hitRule: rule,
                risk: hit.riskLevel,
                tags: hit.tag.map { [$0] } ?? [],
                data: hit.data.mapValues { .number($0) },
                summary: "评估完成，风险等级: \(hit.riskLevel.rawValue)",
                ruleset: ruleset,
                registry: registry
            )
        }
        return (domains, quality)
    }

    /// 与黄金用例一致：先在真正命中条件（带 tag）的规则里取最高优先级，
    /// 避免高优先级规则的 default_risk 盖住低血压等特异性规则。
    private static func selectBestSinglePoint(
        rules: [ClinicalRule],
        measurements: [String: Double]
    ) -> ClinicalEvaluators.SinglePointHit? {
        var tagged: ClinicalEvaluators.SinglePointHit?
        var taggedPriority = -1
        var fallback: ClinicalEvaluators.SinglePointHit?
        var fallbackPriority = -1
        for rule in rules {
            guard let hit = ClinicalEvaluators.evaluateSinglePoint(rule: rule, measurements: measurements) else { continue }
            if hit.tagged, rule.priority > taggedPriority {
                tagged = hit
                taggedPriority = rule.priority
            }
            if rule.priority > fallbackPriority {
                fallback = hit
                fallbackPriority = rule.priority
            }
        }
        return tagged ?? fallback
    }

    private static func runTrend(
        _ history: [ClinicalHistoryPoint],
        ruleset: ClinicalRuleset,
        registry: ClinicalRulesetRegistry,
        now: Date
    ) -> ([String: ClinicalDomainResult], [ClinicalQualityIssue]) {
        var quality: [ClinicalQualityIssue] = []
        var measurements: [ClinicalMeasurement] = []
        for point in history {
            let converted = registry.convert(metric: point.metric, value: point.value, unit: point.unit)
            if !registry.isPlausible(metric: point.metric, value: converted) {
                quality.append(ClinicalQualityIssue(metric: point.metric, value: converted, reason: "out_of_range"))
                continue
            }
            let unit = registry.metrics[point.metric]?.unitCanonical ?? point.unit
            measurements.append(
                ClinicalMeasurement(
                    metric: point.metric,
                    value: converted,
                    unit: unit,
                    timestamp: point.timestamp,
                    deviceID: point.deviceID,
                    tags: point.tags
                )
            )
        }

        var grouped: [String: [ClinicalMeasurement]] = [:]
        for item in measurements {
            grouped[item.metric, default: []].append(item)
        }

        var trendRules: [String: [ClinicalRule]] = [:]
        for rule in ruleset.rules where rule.type == "trend" && rule.enabled {
            for metric in rule.required {
                trendRules[metric, default: []].append(rule)
            }
        }

        var domains: [String: ClinicalDomainResult] = [:]
        for (metric, rules) in trendRules {
            guard let series = grouped[metric] else { continue }
            var tagged: ClinicalEvaluators.TrendHit?
            var taggedPriority = -1
            var fallback: ClinicalEvaluators.TrendHit?
            var fallbackPriority = -1
            var chosenRule: ClinicalRule?
            for rule in rules {
                guard let hit = ClinicalEvaluators.evaluateTrend(rule: rule, measurements: series, now: now) else { continue }
                if hit.tagged, rule.priority > taggedPriority {
                    tagged = hit
                    taggedPriority = rule.priority
                    chosenRule = rule
                }
                if rule.priority > fallbackPriority {
                    fallback = hit
                    fallbackPriority = rule.priority
                    if tagged == nil { chosenRule = rule }
                }
            }
            let hit = tagged ?? fallback
            guard let hit, let rule = chosenRule ?? rules.first(where: { $0.id == hit.ruleID }) else { continue }
            if !hit.tagged, hit.riskLevel == .normal { continue }
            domains[metric] = makeDomain(
                domain: metric,
                hitRule: rule,
                risk: hit.riskLevel,
                tags: hit.tag.map { [$0] } ?? [],
                data: hit.aggregates,
                summary: "趋势评估完成，风险等级: \(hit.riskLevel.rawValue)",
                ruleset: ruleset,
                registry: registry
            )
        }
        return (domains, quality)
    }

    private static func makeDomain(
        domain: String,
        hitRule: ClinicalRule,
        risk: ClinicalRiskLevel,
        tags: [String],
        data: [String: ClinicalJSON],
        summary: String,
        ruleset: ClinicalRuleset,
        registry: ClinicalRulesetRegistry
    ) -> ClinicalDomainResult {
        let evidence = hitRule.evidence.map {
            ClinicalEvidence(
                guideline: registry.sourceTitle($0.sourceID, in: ruleset),
                section: $0.section,
                quote: $0.quote
            )
        }
        return ClinicalDomainResult(
            domain: domain,
            riskLevel: risk,
            summary: summary,
            triggeredRules: [
                ClinicalTriggeredRule(
                    ruleID: hitRule.id,
                    riskLevel: risk,
                    evidence: evidence,
                    confidence: hitRule.confidence,
                    data: data,
                    tags: tags
                ),
            ],
            advice: registry.adviceItems(hitRule.adviceIDs)
        )
    }

    private static func makeResult(
        measurementsDigest: [String: Double],
        extra: String?,
        ruleset: ClinicalRuleset,
        registry: ClinicalRulesetRegistry,
        version: String?,
        domains: [String: ClinicalDomainResult],
        quality: [ClinicalQualityIssue]
    ) -> ClinicalEvaluation {
        var payload = measurementsDigest.keys.sorted().map { "\($0)=\(measurementsDigest[$0]!)" }.joined(separator: ",")
        if let extra { payload += extra }
        let digest = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
        return ClinicalEvaluation(
            evaluationID: UUID().uuidString.lowercased(),
            rulesetVersion: ruleset.version,
            rulesetSHA256: registry.sha256(version),
            inputDigest: String(digest.prefix(16)),
            evaluatedAt: Date(),
            domains: domains,
            dataQuality: quality,
            disclaimer: registry.disclaimerCN
        )
    }
}
