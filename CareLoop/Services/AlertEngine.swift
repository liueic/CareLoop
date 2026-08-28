import Foundation

struct AlertDraft: Equatable, Sendable {
    var tier: AlertTier
    var title: String
    var whatChanged: String
    var baselineDelta: String
    var whyItMatters: String
    var suggestedAction: String
    var evidence: String
    var relatedMetricTypes: [MetricType]
    var ruleIDs: [String]
}

struct PopulationHit: Equatable, Sendable {
    var type: MetricType
    var value: Double
    var guideline: String
    var ruleID: String
}

enum AlertEngine: Sendable {
    static func evaluate(
        profile: ProfileTags,
        baselines: [BaselineResult],
        todayMetrics: [HealthMetric],
        recentSymptoms: [SymptomEntry],
        logText: [String],
        highSugarEvent: Bool,
        rules: GuidelineRules
    ) -> [AlertDraft] {
        var drafts: [AlertDraft] = []

        if let redFlag = redFlagAlert(symptoms: recentSymptoms, texts: logText, rules: rules) {
            drafts.append(redFlag)
        }

        let populationHits = populationThresholdHits(metrics: todayMetrics, rules: rules)
        let persistent = baselines.filter(\.persistent)
        let deviations = baselines.filter(\.deviation)

        if let combo = multiMetricDraft(baselines: baselines, profile: profile) {
            drafts.append(combo)
        }

        for hit in populationHits {
            drafts.append(populationDraft(hit: hit, persistent: persistent.contains { $0.metricType == hit.type }))
        }

        for baseline in persistent {
            drafts.append(persistentDraft(baseline, profile: profile))
        }

        for baseline in deviations where !baseline.persistent {
            drafts.append(observeDraft(baseline, profile: profile))
        }

        if highSugarEvent && profile.conditions.contains(where: { $0.contains("糖尿") || $0.contains("代谢") }) {
            drafts.append(
                AlertDraft(
                    tier: .l1,
                    title: "含糖饮食提醒",
                    whatChanged: "记录中出现高糖饮食相关标签。",
                    baselineDelta: "本次为行为提示，不涉及指标 z 值。",
                    whyItMatters: "你的画像中包含糖代谢相关病种，高糖饮食值得被看见，但不等于诊断。",
                    suggestedAction: "可记录实际份量并在复诊时告知医生；如需调整饮食请咨询医生或营养师。",
                    evidence: "规则 ALG-L1-SUGAR；画像病种=\(profile.conditions.joined(separator: ","))",
                    relatedMetricTypes: [.bloodGlucose],
                    ruleIDs: ["ALG-L1-SUGAR"]
                )
            )
        }

        if !recentSymptoms.isEmpty && persistent.count >= 1 {
            let names = recentSymptoms.map(\.name).joined(separator: "、")
            drafts.append(
                AlertDraft(
                    tier: .l4,
                    title: "持续异常并伴随症状记录",
                    whatChanged: "近期指标持续偏离个人基线，同时记录了症状：\(names)。",
                    baselineDelta: persistent.map { formatDelta($0) }.joined(separator: "；"),
                    whyItMatters: "持续偏离叠加主观不适时，更适合由医生协助判断，而不是由 App 下结论。",
                    suggestedAction: "建议尽快咨询医生，并携带本页摘要与手帐记录。",
                    evidence: "规则 ALG-L4-SYMPTOM-PERSIST",
                    relatedMetricTypes: persistent.map(\.metricType),
                    ruleIDs: ["ALG-L4-SYMPTOM-PERSIST"]
                )
            )
        }

        return dedupe(drafts)
    }

    private static func redFlagAlert(symptoms: [SymptomEntry], texts: [String], rules: GuidelineRules) -> AlertDraft? {
        let corpus = (symptoms.map(\.name) + texts).joined(separator: " ")
        let hit = rules.redFlagKeywords.first { corpus.contains($0) }
        guard let hit else { return nil }
        return AlertDraft(
            tier: .l5,
            title: "出现需要尽快就医的症状描述",
            whatChanged: "记录中出现红旗关键词：\(hit)。",
            baselineDelta: "红旗规则不依赖 z 值。",
            whyItMatters: "胸痛、严重头晕、呼吸困难等描述可能对应需要紧急评估的情况。App 不能判断是否为急症。",
            suggestedAction: "如正在发生或迅速加重，请立即拨打当地急救电话或前往急诊。本应用不做诊断。",
            evidence: "规则 ALG-L5-REDFLAG；关键词=\(hit)",
            relatedMetricTypes: [],
            ruleIDs: ["ALG-L5-REDFLAG"]
        )
    }

    private static func populationThresholdHits(metrics: [HealthMetric], rules: GuidelineRules) -> [PopulationHit] {
        var hits: [PopulationHit] = []
        for metric in metrics {
            guard let threshold = rules.populationThresholds[metric.type.rawValue] else { continue }
            if let high = threshold.high, metric.value >= high {
                hits.append(
                    PopulationHit(
                        type: metric.type,
                        value: metric.value,
                        guideline: threshold.guideline ?? "人群参考阈值",
                        ruleID: "POP-\(metric.type.rawValue)-HIGH"
                    )
                )
            }
            if let low = threshold.low, metric.value <= low {
                hits.append(
                    PopulationHit(
                        type: metric.type,
                        value: metric.value,
                        guideline: threshold.guideline ?? "人群参考阈值",
                        ruleID: "POP-\(metric.type.rawValue)-LOW"
                    )
                )
            }
        }
        return hits
    }

    private static func populationDraft(hit: PopulationHit, persistent: Bool) -> AlertDraft {
        AlertDraft(
            tier: persistent ? .l4 : .l4,
            title: "\(hit.type.displayName)越过指南参考线",
            whatChanged: String(format: "%@ 当前值为 %.1f %@", hit.type.displayName, hit.value, hit.type.unit),
            baselineDelta: "此条由人群阈值轨道触发，可能同时存在个人基线偏离。",
            whyItMatters: hit.guideline,
            suggestedAction: "建议复测并咨询医生。App 不会给出诊断或调药建议。",
            evidence: "规则 \(hit.ruleID)",
            relatedMetricTypes: [hit.type],
            ruleIDs: [hit.ruleID]
        )
    }

    private static func persistentDraft(_ baseline: BaselineResult, profile: ProfileTags) -> AlertDraft {
        AlertDraft(
            tier: .l3,
            title: "\(baseline.metricType.displayName)持续偏离个人基线",
            whatChanged: "近 \(baseline.windowDays) 天中，\(baseline.metricType.displayName)持续偏离你自己的常态。",
            baselineDelta: formatDelta(baseline),
            whyItMatters: "个人基线比人群均值更能反映“对你而言是否异常”。病种画像：\(profile.conditions.joined(separator: "、"))。",
            suggestedAction: "建议观察 1–2 天并保持记录；若伴随不适，咨询医生。",
            evidence: "规则 ALG-L3-PERSIST；窗口=\(baseline.windowDays)天",
            relatedMetricTypes: [baseline.metricType],
            ruleIDs: ["ALG-L3-PERSIST"]
        )
    }

    private static func observeDraft(_ baseline: BaselineResult, profile: ProfileTags) -> AlertDraft {
        AlertDraft(
            tier: .l2,
            title: "\(baseline.metricType.displayName)偏离个人基线",
            whatChanged: "今日 \(baseline.metricType.displayName) 相对近 \(baseline.windowDays) 天个人均值出现偏离。",
            baselineDelta: formatDelta(baseline),
            whyItMatters: "单日偏离常见于睡眠不足、压力、感染或漏戴设备，需要连续观察而不是下诊断。画像病种：\(profile.conditions.joined(separator: "、"))。",
            suggestedAction: "可继续记录睡眠、用药和症状；不必因此自行调整药物。",
            evidence: "规则 ALG-L2-Z；|z|≥1.5",
            relatedMetricTypes: [baseline.metricType],
            ruleIDs: ["ALG-L2-Z"]
        )
    }

    private static func multiMetricDraft(baselines: [BaselineResult], profile: ProfileTags) -> AlertDraft? {
        let sleep = baselines.first { $0.metricType == .sleepHours && ($0.deviation || $0.persistent) }
        let rhr = baselines.first { $0.metricType == .restingHeartRate && ($0.deviation || $0.persistent) }
        let steps = baselines.first { $0.metricType == .stepCount && ($0.deviation || $0.persistent) }
        guard sleep != nil, rhr != nil, steps != nil else { return nil }
        return AlertDraft(
            tier: .l3,
            title: "睡眠、静息心率与活动量同时偏离",
            whatChanged: "睡眠下降、静息心率上升与活动量异常同时出现。",
            baselineDelta: [sleep, rhr, steps].compactMap { $0.map(formatDelta) }.joined(separator: "；"),
            whyItMatters: "多指标同向变化比单点波动更值得被看见。这仍不是诊断。画像：\(profile.conditions.joined(separator: "、"))。",
            suggestedAction: "优先休息与复测；若出现胸痛、严重头晕等，请及时就医。",
            evidence: "规则 ALG-L3-MULTI",
            relatedMetricTypes: [.sleepHours, .restingHeartRate, .stepCount],
            ruleIDs: ["ALG-L3-MULTI"]
        )
    }

    private static func formatDelta(_ baseline: BaselineResult) -> String {
        let today = baseline.today.map { String(format: "%.2f", $0) } ?? "—"
        let z = baseline.zScore.map { String(format: "%.2f", $0) } ?? "—"
        return "\(baseline.metricType.displayName) 今日 \(today)（均值 \(String(format: "%.2f", baseline.mean))，SD \(String(format: "%.2f", baseline.stdDev))，z=\(z)）"
    }

    private static func dedupe(_ drafts: [AlertDraft]) -> [AlertDraft] {
        var seen: Set<String> = []
        var result: [AlertDraft] = []
        let sorted = drafts.sorted { $0.tier > $1.tier }
        for draft in sorted {
            let key = draft.ruleIDs.joined() + draft.relatedMetricTypes.map(\.rawValue).joined()
            if seen.insert(key).inserted {
                result.append(draft)
            }
        }
        return result
    }
}
