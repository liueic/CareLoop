import Foundation
import Testing

@testable import CareLoop

/// 处方用法用量解析：中文数字频次、拉丁缩写、单次剂量、餐前/睡前时间映射、疗程。
struct PrescriptionParserTests {
    // MARK: 频次

    @Test func arabicAndChineseFrequencies() {
        #expect(PrescriptionParser.frequencyPerDay(from: "每日3次") == 3)
        #expect(PrescriptionParser.frequencyPerDay(from: "每日三次") == 3)
        #expect(PrescriptionParser.frequencyPerDay(from: "一天两次") == 2)
        #expect(PrescriptionParser.frequencyPerDay(from: "每日1次，餐前服") == 1)
        #expect(PrescriptionParser.frequencyPerDay(from: "每日2次，每次0.5g") == 2)
    }

    @Test func latinAbbreviations() {
        #expect(PrescriptionParser.frequencyPerDay(from: "bid") == 2)
        #expect(PrescriptionParser.frequencyPerDay(from: "TID") == 3)
        #expect(PrescriptionParser.frequencyPerDay(from: "qd") == 1)
        #expect(PrescriptionParser.frequencyPerDay(from: "q8h") == 3)
        #expect(PrescriptionParser.frequencyPerDay(from: "q12h") == 2)
    }

    @Test func frequencyEdgeCases() {
        #expect(PrescriptionParser.frequencyPerDay(from: nil) == nil)
        #expect(PrescriptionParser.frequencyPerDay(from: "") == nil)
        // "必要时"无数字，由调用方默认 1 并附加特殊医嘱提示
        #expect(PrescriptionParser.frequencyPerDay(from: "必要时服用") == nil)
        // 旧版兼容：纯剂量文本回退第一个数字
        #expect(PrescriptionParser.frequencyPerDay(from: "每次1片") == 1)
    }

    @Test func specialInstructions() {
        #expect(PrescriptionParser.specialInstructions(from: "隔日一次") != nil)
        #expect(PrescriptionParser.specialInstructions(from: "qod") != nil)
        #expect(PrescriptionParser.specialInstructions(from: "必要时服 1 片") != nil)
        #expect(PrescriptionParser.specialInstructions(from: "每日3次") == nil)
        #expect(PrescriptionParser.specialInstructions(from: nil) == nil)
    }

    // MARK: 单次剂量

    @Test func dosePerTake() {
        #expect(PrescriptionParser.dosePerTake(from: "每次1片") == "1片")
        #expect(PrescriptionParser.dosePerTake(from: "每次 0.5g") == "0.5g")
        #expect(PrescriptionParser.dosePerTake(from: "一次2粒") == "2粒")
        #expect(PrescriptionParser.dosePerTake(from: "每次半片") == "0.5片")
        #expect(PrescriptionParser.dosePerTake(from: "每次 500mg") == "500mg")
        #expect(PrescriptionParser.dosePerTake(from: "每日3次") == nil)
        #expect(PrescriptionParser.dosePerTake(from: nil) == nil)
    }

    // MARK: 服药时间

    @Test func mealAndSleepSemantics() {
        #expect(
            PrescriptionParser.timesOfDay(frequency: 3, sig: "每日3次，餐前服")
                == ["07:00", "11:00", "17:00"]
        )
        #expect(
            PrescriptionParser.timesOfDay(frequency: 2, sig: "饭后服用")
                == ["08:00", "12:00"]
        )
        #expect(
            PrescriptionParser.timesOfDay(frequency: 1, sig: "每晚睡前")
                == ["22:00"]
        )
        #expect(
            PrescriptionParser.timesOfDay(frequency: 2, sig: "睡前")
                == ["08:00", "22:00"]
        )
        #expect(
            PrescriptionParser.timesOfDay(frequency: 3, sig: nil)
                == ["08:00", "14:00", "20:00"]
        )
    }

    @Test func defaultTimesByFrequency() {
        #expect(PrescriptionParser.defaultTimes(for: 1) == ["08:00"])
        #expect(PrescriptionParser.defaultTimes(for: 2) == ["08:00", "20:00"])
        #expect(PrescriptionParser.defaultTimes(for: 3) == ["08:00", "14:00", "20:00"])
        #expect(PrescriptionParser.defaultTimes(for: 6) == Array(repeating: "08:00", count: 6))
    }

    // MARK: 疗程与日期

    @Test func periodTextNormalization() {
        #expect(PrescriptionParser.periodText(from: "7天") == "7天")
        #expect(PrescriptionParser.periodText(from: "  两周 ") == "两周")
        #expect(PrescriptionParser.periodText(from: "") == nil)
        #expect(PrescriptionParser.periodText(from: nil) == nil)
    }

    @Test func isoDateParsing() {
        let parsed = PrescriptionParser.parseDate("2026-08-01")
        #expect(parsed != nil)
        let components = Calendar.current.dateComponents([.year, .month, .day], from: parsed!)
        #expect(components == DateComponents(year: 2026, month: 8, day: 1))
        #expect(PrescriptionParser.parseDate("不合法") == nil)
        #expect(PrescriptionParser.parseDate(nil) == nil)
    }
}
