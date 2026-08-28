import Foundation

// MARK: - 输入模型

struct MetricThresholdInfo: Sendable {
    var low: Double?
    var high: Double?
    var unit: String?
    var guideline: String?
}

struct MetricDeviation: Identifiable, Sendable {
    enum Direction: Sendable {
        case above, below
    }

    var id: String { type.rawValue }
    var type: MetricType
    var value: Double
    var direction: Direction
    var threshold: MetricThresholdInfo

    var directionText: String {
        switch direction {
        case .above: "高于"
        case .below: "低于"
        }
    }

    var exceededBound: Double {
        switch direction {
        case .above: threshold.high ?? value
        case .below: threshold.low ?? value
        }
    }

    var valueText: String {
        Self.numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    var boundText: String {
        Self.numberFormatter.string(from: NSNumber(value: exceededBound)) ?? "\(exceededBound)"
    }

    var rangeText: String {
        let unit = threshold.unit ?? type.unit
        switch (threshold.low, threshold.high) {
        case let (low?, high?):
            return "参考区间 \(Self.numberFormatter.string(from: NSNumber(value: low)) ?? "")–\(Self.numberFormatter.string(from: NSNumber(value: high)) ?? "") \(unit)"
        case let (nil, high?):
            return "参考上限 <\(Self.numberFormatter.string(from: NSNumber(value: high)) ?? "") \(unit)"
        case let (low?, nil):
            return "参考下限 ≥\(Self.numberFormatter.string(from: NSNumber(value: low)) ?? "") \(unit)"
        default:
            return ""
        }
    }

    static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}

struct MetabolicSyndromeInput: Sendable {
    var waist: Double?
    var triglycerides: Double?
    var systolic: Double?
    var diastolic: Double?
    var fastingGlucose: Double?
    var hdl: Double?
    var isFemale: Bool

    struct ItemResult: Identifiable, Sendable {
        var id: String { name }
        var name: String
        var valueText: String
        var abnormal: Bool
        var directionText: String
        var standardText: String
    }

    var items: [ItemResult] {
        var results: [ItemResult] = []
        if let waist {
            let limit = isFemale ? 85.0 : 90.0
            let abnormal = waist >= limit
            results.append(ItemResult(
                name: "腰围",
                valueText: "\(MetricDeviation.numberFormatter.string(from: NSNumber(value: waist)) ?? "")cm",
                abnormal: abnormal,
                directionText: abnormal ? "高于" : "符合",
                standardText: isFemale ? "女性 <85cm" : "男性 <90cm"
            ))
        }
        if let triglycerides {
            let abnormal = triglycerides >= 1.7
            results.append(ItemResult(
                name: "甘油三酯",
                valueText: "\(MetricDeviation.numberFormatter.string(from: NSNumber(value: triglycerides)) ?? "")mmol/L",
                abnormal: abnormal,
                directionText: abnormal ? "高于" : "符合",
                standardText: "<1.7mmol/L"
            ))
        }
        if let systolic, let diastolic {
            let abnormal = systolic >= 130 || diastolic >= 85
            results.append(ItemResult(
                name: "血压",
                valueText: "\(Int(systolic))/\(Int(diastolic))mmHg",
                abnormal: abnormal,
                directionText: abnormal ? "高于" : "符合",
                standardText: "<130/85mmHg"
            ))
        }
        if let fastingGlucose {
            let abnormal = fastingGlucose >= 6.1
            results.append(ItemResult(
                name: "空腹血糖",
                valueText: "\(MetricDeviation.numberFormatter.string(from: NSNumber(value: fastingGlucose)) ?? "")mmol/L",
                abnormal: abnormal,
                directionText: abnormal ? "高于" : "符合",
                standardText: "<6.1mmol/L"
            ))
        }
        if let hdl {
            let limit = isFemale ? 1.3 : 1.0
            let abnormal = hdl < limit
            results.append(ItemResult(
                name: "高密度脂蛋白",
                valueText: "\(MetricDeviation.numberFormatter.string(from: NSNumber(value: hdl)) ?? "")mmol/L",
                abnormal: abnormal,
                directionText: abnormal ? "低于" : "符合",
                standardText: isFemale ? "女性 ≥1.3mmol/L" : "男性 ≥1.0mmol/L"
            ))
        }
        return results
    }

    var abnormalCount: Int { items.filter(\.abnormal).count }
}

// MARK: - 输出模型

struct MetricInsight: Equatable, Sendable {
    var title: String
    var visualization: String
    var interpretation: [String]
    var risks: [String]
    var actions: [String]
    var disclaimer: String
    var usedLLM: Bool
}

// MARK: - 提示词与生成

enum MetricInsightService {

    static let sharedRedLines = """
    红线：你不是医生，不能下诊断；不能讨论药物剂量、停药、加量、换药；\
    必须明确说明每一项指标是“高于”还是“低于”参考标准；语言平实、温和、可执行；\
    所有内容标注“仅供参考，不构成诊断”。
    """

    static let sharedSystemPrompt = """
    你是一名专业的健康管理师，正在为一款慢病管理 App 的用户解读健康指标。\
    输出风格参考 Apple Health 的平实科普语气。\
    你必须只输出一个 JSON 对象，不要输出任何其他文字或代码围栏。\
    JSON 结构：{"title":"...","visualization":"...","interpretation":["..."],"risks":["..."],"actions":["..."]}。\
    \(sharedRedLines)
    """

    // MARK: 单指标（房颤负荷 / 睡眠结构 / TIR / 其他阈值指标）

    static func singleMetricPrompt(
        deviation: MetricDeviation,
        conditions: [String],
        doctorAdvice: String?
    ) -> LLMPrompt {
        let t = deviation.type
        let valueText = "\(deviation.valueText)\(t.unit)"
        let user = """
        \(sharedRedLines)
        用户病种画像：\(conditions.isEmpty ? "未填写" : conditions.joined(separator: "、"))
        医嘱/处方备注：\(doctorAdvice ?? "无")
        指标：\(t.displayName)，当前值 \(valueText)，\(deviation.directionText)参考标准（\(deviation.rangeText)）。
        指南依据：\(deviation.threshold.guideline ?? t.wearableReferenceNote ?? "人群参考阈值")

        请生成一段指标解读，要求：
        1. 正常值对比：明确指出当前值相比参考标准是偏高还是偏低，偏离了多少。
        2. 风险分层：说明该数值在临床上大致属于哪个风险层级（低/中/高），以及相关并发症风险的变化。
        3. 影响解释：用平实语言解释持续异常对记忆力、情绪、身体恢复或心血管等方面的具体影响。
        4. 可视化建议（填入 visualization 字段）：描述一种直观的图表形式（如计量表、堆叠条形图、环形图），\
        说明用户当前值落在从“安全区”到“风险区”的哪个位置。
        5. 行动建议：结合用户病种画像，给出 2–3 条生活方式层面的初步建议，并提醒咨询医生。
        """
        return LLMPrompt(system: Self.sharedSystemPrompt, user: user, images: [], maxTokens: 900)
    }

    // MARK: 代谢综合征组合

    static func metabolicSyndromePrompt(
        input: MetabolicSyndromeInput,
        conditions: [String],
        doctorAdvice: String?
    ) -> LLMPrompt {
        let lines = input.items.map { item in
            "- \(item.name)：当前 \(item.valueText)，\(item.directionText)标准（\(item.standardText)）"
        }.joined(separator: "\n")
        let user = """
        \(sharedRedLines)
        用户病种画像：\(conditions.isEmpty ? "未填写" : conditions.joined(separator: "、"))
        医嘱/处方备注：\(doctorAdvice ?? "无")
        代谢综合征指标（共 \(input.items.count) 项，异常 \(input.abnormalCount) 项）：
        \(lines)

        请生成一份代谢健康摘要，要求：
        1. 可视化建议（填入 visualization 字段）：描述如何用仪表盘或雷达图直观对比用户各项测量值与指南标准值，\
        标明哪些指标落在绿色安全区、哪些落入红色高风险区。
        2. 明确偏离方向：逐项说明用户的指标是高于还是低于标准值。
        3. 风险告知：用平实语言解释，若这些指标持续异常，对心血管、肝脏等可能带来哪些风险；\
        若异常项达到 3 项及以上，说明其符合代谢综合征的临床筛查特征。
        4. 行动建议：结合用户的病种画像与医嘱，给出初步的生活方式调整建议（饮食、运动），\
        并把“尽快咨询医生、制定个性化干预方案”列为首要任务。
        """
        return LLMPrompt(system: Self.sharedSystemPrompt, user: user, images: [], maxTokens: 1200)
    }

    // MARK: 生成入口

    static func generate(
        deviation: MetricDeviation,
        conditions: [String],
        doctorAdvice: String?,
        llm: any LLMProviding
    ) async -> MetricInsight {
        let prompt = singleMetricPrompt(deviation: deviation, conditions: conditions, doctorAdvice: doctorAdvice)
        if let insight = await request(prompt: prompt) {
            return insight
        }
        return templateInsight(deviation: deviation)
    }

    static func generateMetabolic(
        input: MetabolicSyndromeInput,
        conditions: [String],
        doctorAdvice: String?,
        llm: any LLMProviding
    ) async -> MetricInsight {
        let prompt = metabolicSyndromePrompt(input: input, conditions: conditions, doctorAdvice: doctorAdvice)
        if let insight = await request(prompt: prompt) {
            return insight
        }
        return templateMetabolic(input: input)
    }

    private static func request(prompt: LLMPrompt) async -> MetricInsight? {
        guard let response = try? await llm.complete(prompt: prompt),
              let object = LLMJSON.object(from: response.text) else { return nil }
        let title = object["title"] as? String ?? "指标解读"
        let visualization = object["visualization"] as? String ?? ""
        let interpretation = object["interpretation"] as? [String] ?? []
        let risks = object["risks"] as? [String] ?? []
        let actions = object["actions"] as? [String] ?? []
        guard !interpretation.isEmpty || !risks.isEmpty else { return nil }
        return MetricInsight(
            title: title,
            visualization: visualization,
            interpretation: interpretation,
            risks: risks,
            actions: actions,
            disclaimer: CareLoopCopy.aiAdviceDisclaimer,
            usedLLM: true
        )
    }

    // MARK: 本地模板兜底

    static func templateInsight(deviation: MetricDeviation) -> MetricInsight {
        let t = deviation.type
        let valueText = "\(deviation.valueText)\(t.unit)"
        let compare = "您当前的\(t.displayName)为 \(valueText)，\(deviation.directionText)参考标准（\(deviation.rangeText)）。"
        let meaning: String
        let risk: String
        var actions: [String] = ["咨询医生：建议携带近期数据与医生讨论这个结果，评估是否需要进一步检查或干预。"]
        switch t {
        case .afBurden:
            meaning = "房颤负荷表示在监测时间内，心房颤动发作所占的时间比例。"
            risk = "根据临床参考，负荷在 1%–10% 属于中等水平：中风风险约为正常人的 2–3 倍；若不加干预继续升高至 10% 以上，心衰风险将显著上升。"
            actions.append("生活方式管理：遵医嘱管理血压与血糖，避免熬夜、过量饮酒或咖啡，这些都可能诱发房颤。")
        case .sleepREMPercent:
            meaning = "REM（快速眼动）睡眠对记忆巩固和情绪处理至关重要，健康成人约占 20%–25%。"
            risk = "长期 REM 不足可能导致白天注意力不集中、情绪易波动，并影响学习记忆能力。"
            actions.append("改善睡眠卫生：固定作息时间，睡前避免使用电子设备，营造安静黑暗的睡眠环境。")
        case .sleepDeepPercent:
            meaning = "深睡是身体进行细胞修复、免疫系统增强的黄金时间，健康成人约占 10%–15%（随年龄递减）。"
            risk = "长期深睡不足会影响身体恢复力、免疫功能与代谢健康。"
            actions.append("改善睡眠卫生：白天适度运动、睡前避免饮酒和过饱进食，有助于增加深睡时长。")
        case .cgmTIR:
            meaning = "TIR 表示一天中血糖处于目标范围内的时间比例，糖尿病患者通常建议 >70%。"
            risk = "TIR 持续偏低意味着血糖波动增大，长期会增加糖尿病微血管（眼病、肾病）与大血管（心脏病、中风）并发症风险。"
            actions.append("继续保持记录：与医生一起回顾高血糖或低血糖出现的时段，调整饮食与用药时间。")
        case .sleepHours:
            meaning = "与最低心血管风险相关的睡眠区间为 6.5–7.5 小时。"
            risk = "长期睡眠不足 6.5 小时，主要心血管事件风险约升高 24%，并影响情绪与日间精力。"
            actions.append("优先保证总睡眠时长达到 7 小时以上，这比纠结单个睡眠阶段更重要。")
        case .stepCount:
            meaning = "每日 8,000–9,000 步是糖尿病与高血压风险下降的平台期。"
            risk = "长期低于 5,000 步/天属于久坐型生活方式，与心血管事件风险升高相关。"
            actions.append("循序渐进增加活动量，例如每天比当前多走 500–1000 步，以能够对话、不头晕为度。")
        default:
            meaning = deviation.threshold.guideline ?? t.wearableReferenceNote ?? "该指标已越过人群参考阈值。"
            risk = "若该指标持续异常，建议由医生结合您的整体情况评估其对健康的长期影响。"
        }
        return MetricInsight(
            title: "您的\(t.displayName)解读",
            visualization: "此处可插入参考区间量表：绿色为安全区（\(deviation.rangeText)），您的当前值 \(valueText) 落在区间外，以红点标示。",
            interpretation: [compare, meaning],
            risks: [risk],
            actions: actions,
            disclaimer: CareLoopCopy.aiAdviceDisclaimer,
            usedLLM: false
        )
    }

    static func templateMetabolic(input: MetabolicSyndromeInput) -> MetricInsight {
        let abnormalItems = input.items.filter(\.abnormal)
        let interpretation = input.items.map { item in
            if item.abnormal {
                "\(item.name)：您当前为 \(item.valueText)，\(item.directionText)推荐标准（\(item.standardText)）。"
            } else {
                "\(item.name)：您当前为 \(item.valueText)，符合推荐标准（\(item.standardText)）。"
            }
        }
        var riskText = "异常项包括：\(abnormalItems.map(\.name).joined(separator: "、"))。这些指标持续异常会显著增加未来罹患 2 型糖尿病和心脑血管疾病（如冠心病、脑卒中）的风险，腹型肥胖与血脂异常也会加重肝脏负担（脂肪肝风险）。"
        if input.abnormalCount >= 3 {
            riskText = "您有 \(input.abnormalCount) 项指标异常，达到 3 项及以上即符合代谢综合征的临床筛查特征。" + riskText
        }
        return MetricInsight(
            title: "您的代谢健康概览",
            visualization: "此处可插入雷达图：五个轴分别为腰围、甘油三酯、血压、空腹血糖、高密度脂蛋白；绿色区域为指南安全区，您的测量值超出的轴落在红色高风险区。",
            interpretation: interpretation,
            risks: [riskText],
            actions: [
                "首要任务：请务必咨询您的医生，全面评估并制定个性化的干预方案。",
                "生活方式：结合医嘱，可尝试增加运动、调整饮食结构（减少精制碳水和不健康脂肪的摄入，控制总热量）。",
            ],
            disclaimer: CareLoopCopy.aiAdviceDisclaimer,
            usedLLM: false
        )
    }
}
