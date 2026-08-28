import Foundation

enum ClinicalEvaluators {
    struct SinglePointHit {
        var ruleID: String
        var riskLevel: ClinicalRiskLevel
        var tag: String?
        var data: [String: Double]
        var tagged: Bool { tag != nil }
    }

    struct TrendHit {
        var ruleID: String
        var riskLevel: ClinicalRiskLevel
        var tag: String?
        var aggregates: [String: ClinicalJSON]
        var tagged: Bool { tag != nil }
    }

    static func checkThreshold(value: Double, condition: ClinicalJSON) -> Bool {
        guard let object = condition.object else { return true }
        if let gte = object["gte"]?.number, value < gte { return false }
        if let gt = object["gt"]?.number, value <= gt { return false }
        if let lt = object["lt"]?.number, value >= lt { return false }
        if let lte = object["lte"]?.number, value > lte { return false }
        if let eq = object["eq"]?.number, value != eq { return false }
        return true
    }

    static func evaluateSinglePoint(rule: ClinicalRule, measurements: [String: Double]) -> SinglePointHit? {
        for metric in rule.required where measurements[metric] == nil {
            return nil
        }
        let anyBranches = rule.conditions["any"]?.array ?? []
        let defaultRisk = ClinicalRiskLevel(rawValue: rule.conditions.stringValue("default_risk") ?? "normal") ?? .normal

        for branch in anyBranches {
            guard let allConditions = branch["all"]?.object else { continue }
            var allMatch = true
            for (metric, threshold) in allConditions {
                guard let value = measurements[metric], checkThreshold(value: value, condition: threshold) else {
                    allMatch = false
                    break
                }
            }
            if allMatch {
                let risk = ClinicalRiskLevel(rawValue: branch.stringValue("output_risk") ?? "normal") ?? .normal
                return SinglePointHit(
                    ruleID: rule.id,
                    riskLevel: risk,
                    tag: branch.stringValue("tag"),
                    data: measurements
                )
            }
        }

        return SinglePointHit(ruleID: rule.id, riskLevel: defaultRisk, tag: nil, data: measurements)
    }

    static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    static func std(_ values: [Double], mean: Double) -> Double {
        guard values.count >= 2 else { return 0 }
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return variance.squareRoot()
    }

    static func olsSlopePerWeek(times: [Date], values: [Double]) -> Double {
        guard times.count >= 2 else { return 0 }
        let t0 = times[0]
        let x = times.map { $0.timeIntervalSince(t0) / 86_400 }
        let n = Double(times.count)
        let xMean = x.reduce(0, +) / n
        let yMean = values.reduce(0, +) / n
        var numerator = 0.0
        var denominator = 0.0
        for i in x.indices {
            numerator += (x[i] - xMean) * (values[i] - yMean)
            denominator += (x[i] - xMean) * (x[i] - xMean)
        }
        guard denominator != 0 else { return 0 }
        return (numerator / denominator) * 7
    }

    static func applyWindow(_ measurements: [ClinicalMeasurement], days: Int, now: Date) -> [ClinicalMeasurement] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return measurements.filter { $0.timestamp >= cutoff }
    }

    static func evaluateTrend(
        rule: ClinicalRule,
        measurements: [ClinicalMeasurement],
        now: Date = Date()
    ) -> TrendHit? {
        let windowed = applyWindow(measurements, days: rule.windowDays, now: now)
        if windowed.count < rule.minSamples { return nil }

        let values = windowed.map(\.value)
        let times = windowed.map(\.timestamp)
        let meanVal = mean(values)
        let stdVal = std(values, mean: meanVal)
        let slope = olsSlopePerWeek(times: times, values: values)
        var agg: [String: ClinicalJSON] = [
            "mean": .number((meanVal * 100).rounded() / 100),
            "std": .number((stdVal * 100).rounded() / 100),
            "slope_per_week": .number((slope * 1000).rounded() / 1000),
            "min": .number((values.min()! * 100).rounded() / 100),
            "max": .number((values.max()! * 100).rounded() / 100),
            "count": .number(Double(values.count)),
        ]

        let metric = measurements.first?.metric ?? "unknown"
        if metric == "blood_glucose" {
            let tir = computeTIR(windowed)
            agg.merge(tir) { _, new in new }
        }
        if metric == "sbp" || metric == "dbp", let surge = detectMorningSurge(windowed) {
            agg["morning_surge"] = .number(surge)
            agg["morning_surge_detail"] = .object([
                "surge": .number(surge),
            ])
        }

        let anyBranches = rule.conditions["any"]?.array ?? []
        for branch in anyBranches {
            guard let aggConds = branch["aggregate"]?.object, !aggConds.isEmpty else { continue }
            var match = true
            for (key, threshold) in aggConds {
                guard let raw = agg[key], let value = numericAggregate(raw) else {
                    match = false
                    break
                }
                if !checkThreshold(value: value, condition: threshold) {
                    match = false
                    break
                }
            }
            if match {
                let risk = ClinicalRiskLevel(rawValue: branch.stringValue("output_risk") ?? "normal") ?? .normal
                return TrendHit(
                    ruleID: rule.id,
                    riskLevel: risk,
                    tag: branch.stringValue("tag"),
                    aggregates: agg
                )
            }
        }

        let defaultRisk = ClinicalRiskLevel(rawValue: rule.conditions.stringValue("default_risk") ?? "normal") ?? .normal
        return TrendHit(ruleID: rule.id, riskLevel: defaultRisk, tag: nil, aggregates: agg)
    }

    private static func numericAggregate(_ json: ClinicalJSON) -> Double? {
        if let number = json.number { return number }
        if let surge = json["surge"]?.number { return surge }
        return nil
    }

    private static func computeTIR(_ measurements: [ClinicalMeasurement]) -> [String: ClinicalJSON] {
        guard !measurements.isEmpty else {
            return ["tir": .number(0), "tar": .number(0), "tbr": .number(0)]
        }
        var inRange = 0
        var above = 0
        var below = 0
        for item in measurements {
            if item.value >= 3.9 && item.value <= 10.0 {
                inRange += 1
            } else if item.value > 10.0 {
                above += 1
            } else {
                below += 1
            }
        }
        let total = Double(measurements.count)
        return [
            "tir": .number((Double(inRange) / total * 10_000).rounded() / 100),
            "tar": .number((Double(above) / total * 10_000).rounded() / 100),
            "tbr": .number((Double(below) / total * 10_000).rounded() / 100),
        ]
    }

    private static func detectMorningSurge(_ measurements: [ClinicalMeasurement], threshold: Double = 20) -> Double? {
        let calendar = Calendar.current
        let morning = measurements.filter {
            let hour = calendar.component(.hour, from: $0.timestamp)
            return (5...10).contains(hour)
        }.map(\.value)
        guard morning.count >= 2 else { return nil }
        let morningMean = mean(morning)
        let overall = mean(measurements.map(\.value))
        let surge = (morningMean - overall)
        let rounded = (surge * 100).rounded() / 100
        return rounded >= threshold ? rounded : nil
    }

    static func runComposite(
        measurements: [String: Double],
        domains: [String: ClinicalDomainResult],
        profile: ClinicalUserProfile?,
        ruleset: ClinicalRuleset,
        registry: ClinicalRulesetRegistry
    ) -> [String: ClinicalDomainResult] {
        var result: [String: ClinicalDomainResult] = [:]
        if let ms = metabolicSyndrome(measurements, profile: profile, ruleset: ruleset, registry: registry) {
            result[ms.domain] = ms
        }
        if let ascvd = ascvdRisk(measurements, profile: profile, domains: domains, ruleset: ruleset, registry: registry) {
            result[ascvd.domain] = ascvd
        }
        for item in crossDomain(domains, measurements: measurements, ruleset: ruleset, registry: registry) {
            result[item.domain] = item
        }
        return result
    }

    private static func domainRisk(_ domains: [String: ClinicalDomainResult], _ key: String) -> ClinicalRiskLevel? {
        domains[key]?.riskLevel
    }

    private static func evidence(
        _ ruleset: ClinicalRuleset,
        _ registry: ClinicalRulesetRegistry,
        sourceID: String,
        section: String,
        quote: String?
    ) -> [ClinicalEvidence] {
        [ClinicalEvidence(guideline: registry.sourceTitle(sourceID, in: ruleset), section: section, quote: quote)]
    }

    private static func metabolicSyndrome(
        _ measurements: [String: Double],
        profile: ClinicalUserProfile?,
        ruleset: ClinicalRuleset,
        registry: ClinicalRulesetRegistry
    ) -> ClinicalDomainResult? {
        var factors: [String] = []
        let sex = profile?.sex ?? "male"
        if let waist = measurements["waist"] {
            let threshold = sex == "male" ? 90.0 : 85.0
            if waist >= threshold { factors.append("waist>=\(Int(threshold))cm") }
        }
        if let tg = measurements["tg"], tg >= 1.7 { factors.append("TG>=1.7") }
        if let hdl = measurements["hdl_c"], hdl < 1.04 { factors.append("HDL-C<1.04") }
        let sbp = measurements["sbp"]
        let dbp = measurements["dbp"]
        if let sbp, let dbp {
            if sbp >= 130 || dbp >= 85 { factors.append("BP>=130/85") }
        } else if let sbp, sbp >= 130 {
            factors.append("SBP>=130")
        }
        if let fpg = measurements["blood_glucose"], fpg >= 6.1 { factors.append("FPG>=6.1") }
        guard factors.count >= 3 else { return nil }
        let risk: ClinicalRiskLevel = factors.count >= 4 ? .high : .medium
        return ClinicalDomainResult(
            domain: "metabolic_syndrome",
            riskLevel: risk,
            summary: "代谢综合征筛查：发现\(factors.count)/5项异常指标（\(factors.joined(separator: "、"))），≥3项即为代谢综合征",
            triggeredRules: [
                ClinicalTriggeredRule(
                    ruleID: "CMP-MS-001",
                    riskLevel: risk,
                    evidence: evidence(
                        ruleset,
                        registry,
                        sourceID: "CDS-2020",
                        section: "代谢综合征诊断标准（CDS 2004）",
                        quote: "具备以下3项或全部者：腰围超标、TG升高、HDL-C降低、血压升高、空腹血糖升高"
                    ),
                    confidence: "high",
                    data: [
                        "factor_count": .number(Double(factors.count)),
                        "factors": .array(factors.map { .string($0) }),
                    ],
                    tags: ["metabolic_syndrome"]
                ),
            ],
            advice: registry.adviceItems(["AD-CMP-101"])
        )
    }

    private static func ascvdRisk(
        _ measurements: [String: Double],
        profile: ClinicalUserProfile?,
        domains: [String: ClinicalDomainResult],
        ruleset: ClinicalRuleset,
        registry: ClinicalRulesetRegistry
    ) -> ClinicalDomainResult? {
        var factors: [String] = []
        let sex = profile?.sex ?? "male"
        if let age = profile?.age {
            if (sex == "male" && age >= 45) || (sex == "female" && age >= 55) {
                factors.append("age_risk")
            }
        }
        if let ldl = measurements["ldl_c"], ldl >= 4.1 { factors.append("LDL-C>=4.1") }
        if let tc = measurements["tc"], tc >= 6.2 { factors.append("TC>=6.2") }
        if let hdl = measurements["hdl_c"], hdl < 1.0 { factors.append("HDL-C<1.0") }
        if let sbpRisk = domainRisk(domains, "sbp"), sbpRisk.rank >= ClinicalRiskLevel.medium.rank {
            factors.append("hypertension")
        }
        if let glucoseRisk = domainRisk(domains, "blood_glucose"), glucoseRisk.rank >= ClinicalRiskLevel.medium.rank {
            factors.append("diabetes_risk")
        }
        if profile?.smoking == true { factors.append("smoking") }
        guard !factors.isEmpty else { return nil }
        let count = factors.count
        let risk: ClinicalRiskLevel = count >= 4 ? .high : count >= 2 ? .medium : .lowElevated
        return ClinicalDomainResult(
            domain: "ascvd_risk",
            riskLevel: risk,
            summary: "ASCVD风险因子计数：\(count)项（\(factors.joined(separator: "、"))）",
            triggeredRules: [
                ClinicalTriggeredRule(
                    ruleID: "CMP-ASCVD-001",
                    riskLevel: risk,
                    evidence: evidence(
                        ruleset,
                        registry,
                        sourceID: "CVD-PREV-2020",
                        section: "心血管病一级预防指南, China-PAR风险模型",
                        quote: "多项危险因素聚集显著增加ASCVD 10年风险"
                    ),
                    confidence: "medium",
                    data: [
                        "factor_count": .number(Double(count)),
                        "factors": .array(factors.map { .string($0) }),
                    ],
                    tags: ["ascvd_risk_factors"]
                ),
            ],
            advice: registry.adviceItems(["AD-CMP-101", "AD-CMP-102"])
        )
    }

    private static func crossDomain(
        _ domains: [String: ClinicalDomainResult],
        measurements: [String: Double],
        ruleset: ClinicalRuleset,
        registry: ClinicalRulesetRegistry
    ) -> [ClinicalDomainResult] {
        var results: [ClinicalDomainResult] = []
        let bpRisk = domainRisk(domains, "sbp")
        let glucoseRisk = domainRisk(domains, "blood_glucose")
        if let bpRisk, bpRisk.rank >= ClinicalRiskLevel.medium.rank,
           let glucoseRisk, glucoseRisk.rank >= ClinicalRiskLevel.medium.rank {
            let escalated = ClinicalRiskLevel.max(ClinicalRiskLevel.max(bpRisk, glucoseRisk), .high)
            results.append(
                ClinicalDomainResult(
                    domain: "htn_diabetes_escalation",
                    riskLevel: escalated,
                    summary: "高血压合并血糖异常，心血管风险显著升高，需综合管理",
                    triggeredRules: [
                        ClinicalTriggeredRule(
                            ruleID: "CMP-ESC-001",
                            riskLevel: escalated,
                            evidence: evidence(
                                ruleset,
                                registry,
                                sourceID: "CVD-PREV-2020",
                                section: "高血压合并糖尿病管理",
                                quote: "高血压合并糖尿病患者ASCVD风险显著升高，血压目标<130/80mmHg，LDL-C目标<1.8mmol/L"
                            ),
                            confidence: "high",
                            data: [
                                "bp_risk": .string(bpRisk.rawValue),
                                "glucose_risk": .string(glucoseRisk.rawValue),
                            ],
                            tags: ["cross_domain_escalation", "htn_diabetes"]
                        ),
                    ],
                    advice: registry.adviceItems(["AD-CMP-101", "AD-CMP-103"])
                )
            )
        }

        if let spo2Night = measurements["spo2_night_min"], spo2Night < 90,
           let bpRisk, bpRisk.rank >= ClinicalRiskLevel.lowElevated.rank {
            results.append(
                ClinicalDomainResult(
                    domain: "osa_screening",
                    riskLevel: .medium,
                    summary: "夜间血氧最低值<90%合并血压升高，提示阻塞性睡眠呼吸暂停（OSA）可能，建议专业评估",
                    triggeredRules: [
                        ClinicalTriggeredRule(
                            ruleID: "CMP-OSA-001",
                            riskLevel: .medium,
                            evidence: evidence(
                                ruleset,
                                registry,
                                sourceID: "CVD-PREV-2020",
                                section: "OSA与心血管风险",
                                quote: "OSA是高血压的独立危险因素，夜间SpO2<90%需筛查OSA"
                            ),
                            confidence: "medium",
                            data: [
                                "spo2_night_min": .number(spo2Night),
                                "bp_risk": .string(bpRisk.rawValue),
                            ],
                            tags: ["osa_screening"]
                        ),
                    ],
                    advice: registry.adviceItems(["AD-SLP-102"])
                )
            )
        }

        if let ldl = measurements["ldl_c"], ldl >= 4.9,
           let bpRisk, bpRisk.rank >= ClinicalRiskLevel.medium.rank {
            results.append(
                ClinicalDomainResult(
                    domain: "extreme_ldl_hypertension",
                    riskLevel: .high,
                    summary: "LDL-C≥4.9mmol/L合并高血压，属于极高心血管风险，需紧急就医评估",
                    triggeredRules: [
                        ClinicalTriggeredRule(
                            ruleID: "CMP-LDL-ESC-001",
                            riskLevel: .high,
                            evidence: evidence(
                                ruleset,
                                registry,
                                sourceID: "CLG-2023",
                                section: "血脂异常危险分层",
                                quote: "LDL-C≥4.9mmol/L为高危标志，合并高血压时心血管风险极高"
                            ),
                            confidence: "high",
                            data: [
                                "ldl_c": .number(ldl),
                                "bp_risk": .string(bpRisk.rawValue),
                            ],
                            tags: ["extreme_risk"]
                        ),
                    ],
                    advice: registry.adviceItems(["AD-LIP-103", "AD-CMP-103"])
                )
            )
        }
        return results
    }
}
