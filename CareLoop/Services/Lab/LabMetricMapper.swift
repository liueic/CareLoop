import Foundation

/// 化验单条目（`LabValueItem`，OCR 识别或手动录入）→ `HealthMetric` 的映射器（纯函数，可单测）。
///
/// 只映射 `dataSource == .labEntry` 的 5 种指标（hba1c、血脂四项）——
/// 这些类型在 HealthKit 公开 API 中不存在，化验单是唯一来源。
enum LabMetricMapper {
    static let ocrSourceName = "化验单识别"
    static let manualSourceName = "手动录入"
    /// 手动录入表单写入 MedicalDocResult.docType 的标记，用于区分来源展示。
    static let manualDocType = "手动录入"

    /// 名称归一化：小写、去空白与标点（isLetter/isNumber 覆盖中文字符）。
    static func normalizedName(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static let synonyms: [MetricType: Set<String>] = [
        .hba1c: ["糖化血红蛋白", "糖化血红蛋白a1c", "糖化血色素", "hba1c", "a1c", "glycatedhemoglobin"],
        .totalCholesterol: ["总胆固醇", "胆固醇", "血清总胆固醇", "tc", "tcho", "chol", "totalcholesterol"],
        .ldlCholesterol: ["低密度脂蛋白", "低密度脂蛋白胆固醇", "ldl", "ldlc"],
        .hdlCholesterol: ["高密度脂蛋白", "高密度脂蛋白胆固醇", "hdl", "hdlc"],
        .triglycerides: ["甘油三酯", "甘油三脂", "三酰甘油", "血清甘油三酯", "tg", "trig", "triglyceride", "triglycerides"],
    ]

    /// 化验项目名 → 指标类型。中文全称/简称与英文缩写均可；
    /// 精确匹配优先，否则做包含匹配并取**最长**命中的同义词
    /// （避免"高密度脂蛋白胆固醇"被"胆固醇"截胡）。
    static func metricType(forName name: String) -> MetricType? {
        let normalized = normalizedName(name)
        for (type, names) in synonyms where names.contains(normalized) {
            return type
        }
        var best: (type: MetricType, length: Int)?
        for (type, names) in synonyms {
            for synonym in names where normalized.contains(synonym) {
                if synonym.count > (best?.length ?? 0) {
                    best = (type, synonym.count)
                }
            }
        }
        return best?.type
    }

    /// 解析化验值字符串：去掉 `>`、`<`、`≥`、`≤` 与千分位逗号，取第一个数字。
    static func parseValue(_ raw: String) -> Double? {
        let cleaned = raw
            .replacingOccurrences(of: "≥", with: " ")
            .replacingOccurrences(of: "≤", with: " ")
            .replacingOccurrences(of: ">", with: " ")
            .replacingOccurrences(of: "<", with: " ")
            .replacingOccurrences(of: ",", with: "")
        return Scanner(string: cleaned).scanDouble()
    }

    /// 统一到 `MetricType.unit` 声明的显示单位（mmol/L；hba1c 为 %，无换算）。
    /// 美制 mg/dL 报告：胆固醇 ÷38.67，甘油三酯 ÷88.57。
    static func normalizedValue(value: Double, unit: String?, type: MetricType) -> Double {
        guard let unit else { return value }
        let u = unit.lowercased().replacingOccurrences(of: " ", with: "")
        guard u == "mg/dl" || u == "mgdl" else { return value }
        switch type {
        case .triglycerides:
            return value / 88.57
        default:
            return value / 38.67
        }
    }

    /// "2026-08-29" / "2026/08/29" / "2026.08.29" → Date；解析失败返回 nil。
    static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        for format in ["yyyy-MM-dd", "yyyy/MM/dd", "yyyy.MM.dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        return nil
    }

    /// 一份化验单结果 → 规范化的 HealthMetric 列表（跳过无法识别/解析的条目）。
    /// 日期优先取 takenAt，失败回退 fallbackDate（通常是手帐创建时间）。
    static func metrics(from doc: MedicalDocResult, fallbackDate: Date, sourceName: String) -> [HealthMetric] {
        let date = parseDate(doc.takenAt) ?? fallbackDate
        return doc.labValues.compactMap { item in
            guard let type = metricType(forName: item.name),
                  let parsed = parseValue(item.value) else { return nil }
            let value = normalizedValue(value: parsed, unit: item.unit, type: type)
            return HealthMetric(type: type, value: value, date: date, sourceName: sourceName)
        }
    }
}
