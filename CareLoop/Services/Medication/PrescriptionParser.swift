import Foundation

/// 处方用法用量（sig）解析与服药时间推导，纯函数、可单测。
///
/// 中文处方的用法行常见形态："每日3次，每次1片，餐前服"、"bid"、"一天两次，睡前"、
/// "7天量"。频次→具体时间、单次剂量、特殊医嘱与疗程都从这里推导，
/// `CameraCaptureView` 与 `PrescriptionReviewSheet` 共用。
enum PrescriptionParser {
    private static let chineseDigits: [Character: Int] = [
        "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
    ]

    // MARK: - 频次

    /// 用法文本 → 每日次数。拉丁缩写优先，其次 "X次"（阿拉伯/中文数字），再次
    /// "每日/一天 X"，最后回退文本中的第一个数字（与旧版启发式一致）。
    static func frequencyPerDay(from text: String?) -> Int? {
        guard let text, !text.isEmpty else { return nil }
        let lower = text.lowercased()
        let abbreviations: [(String, Int)] = [
            ("tid", 3), ("bid", 2), ("qid", 4),
            ("q6h", 4), ("q8h", 3), ("q12h", 2),
            ("qd", 1), ("qn", 1),
        ]
        for (abbr, value) in abbreviations where lower.contains(abbr) {
            return value
        }
        if let n = numberImmediatelyBefore(lower, unit: "次") {
            return n
        }
        for prefix in ["每日", "每天", "一天", "一日"] {
            if let n = numberImmediatelyAfter(lower, prefix: prefix) {
                return n
            }
        }
        if let digit = lower.first(where: { digitValue(of: $0) != nil }),
           let value = digitValue(of: digit) {
            return value
        }
        return nil
    }

    /// 特殊医嘱（无法折算成固定每日次数的），返回提示文案供 cautions 附加。
    static func specialInstructions(from text: String?) -> String? {
        guard let text else { return nil }
        let lower = text.lowercased()
        if text.contains("隔日") || text.contains("隔天") || lower.contains("qod") {
            return "隔日服用一次，请按医嘱执行"
        }
        if text.contains("必要时") || lower.contains("prn") {
            return "必要时服用，不超过医嘱频次"
        }
        return nil
    }

    // MARK: - 单次剂量

    /// 从用法文本提取单次剂量："每次1片"/"一次 0.5g"/"每次半片" → "1片"/"0.5g"/"0.5片"。
    /// 找不到明确的"每次/一次"表述时返回 nil（剂量可能写在别处，交给用户填写）。
    static func dosePerTake(from text: String?) -> String? {
        guard let text else { return nil }
        for marker in ["每次", "一次"] {
            guard let range = text.range(of: marker) else { continue }
            var rest = text[range.upperBound...].drop { $0 == " " || $0 == "\u{00A0}" }
            // 数量：阿拉伯（可带小数）或中文数字（含"半"）
            var amount = ""
            if rest.first == "半" {
                amount = "0.5"
                rest = rest.dropFirst()
            } else {
                var seenDot = false
                // 仅 ASCII 数字：汉字数字（"三"）的 isNumber 也为 true，会污染剂量文本
                while let first = rest.first,
                      (first.isASCII && first.isNumber) || (first == "." && !seenDot) {
                    if first == "." { seenDot = true }
                    amount.append(first)
                    rest = rest.dropFirst()
                }
            }
            guard !amount.isEmpty else { continue }
            // 单位：中文剂型字或拉丁单位（含 "mg"/"ml" 等）
            var unit = ""
            while let first = rest.first, first.isLetter, unit.count < 4 {
                unit.append(first)
                rest = rest.dropFirst()
                if unit == "mg" || unit == "ml" || unit == "g" { break }
            }
            guard !unit.isEmpty else { continue }
            return amount + unit
        }
        return nil
    }

    // MARK: - 服药时间

    /// 频次 + 用法语义 → 具体服药时刻。餐前/餐后/睡前按语义映射，无语义时用默认分布。
    static func timesOfDay(frequency: Int, sig: String?) -> [String] {
        let lower = (sig ?? "").lowercased()
        if lower.contains("餐前") || lower.contains("饭前") {
            return Array(["07:00", "11:00", "17:00"].prefix(max(1, frequency)))
        }
        if lower.contains("餐后") || lower.contains("饭后") {
            return Array(["08:00", "12:00", "18:00"].prefix(max(1, frequency)))
        }
        var times = defaultTimes(for: frequency)
        if lower.contains("睡前") || lower.contains("qn") {
            if let last = times.indices.last {
                times[last] = "22:00"
            }
        }
        return times
    }

    static func defaultTimes(for frequency: Int) -> [String] {
        switch frequency {
        case 1: ["08:00"]
        case 2: ["08:00", "20:00"]
        case 3: ["08:00", "14:00", "20:00"]
        default: [String](repeating: "08:00", count: max(1, frequency))
        }
    }

    // MARK: - 疗程与日期

    /// 疗程文本（"7天"/"两周"/"一个月"）规范化后作为 `Medication.periodText`；空文本返回 nil。
    static func periodText(from durationText: String?) -> String? {
        guard let trimmed = durationText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// "2026-08-01" → Date（LLM 输出的 takenAt/followUpDate 约定为 YYYY-MM-DD）。
    static func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: text)
    }

    // MARK: - 私有

    /// 数字字符 → 数值。注意 `Character.isNumber` 对汉字数字（"三"/"两"）也为 true，
    /// 但 `Int(String(char))` 只解析 ASCII，所以这里用 `wholeNumberValue`（含 CJK 数字），
    /// chineseDigits 兜底未收录的写法。
    private static func digitValue(of char: Character) -> Int? {
        char.wholeNumberValue ?? chineseDigits[char]
    }

    /// "3次"/"三次" 中"次"前面紧跟的数字（阿拉伯或中文）。"每次1片"的"次"前是"每"，返回 nil。
    private static func numberImmediatelyBefore(_ text: String, unit: String) -> Int? {
        guard let index = text.firstIndex(of: Character(unit)), index > text.startIndex else { return nil }
        return digitValue(of: text[text.index(before: index)])
    }

    /// "每日3次"/"一天两次" 前缀后紧跟的数字。
    private static func numberImmediatelyAfter(_ text: String, prefix: String) -> Int? {
        guard let range = text.range(of: prefix) else { return nil }
        let rest = text[range.upperBound...].drop { $0 == " " || $0 == "\u{00A0}" }
        guard let first = rest.first else { return nil }
        return digitValue(of: first)
    }
}
