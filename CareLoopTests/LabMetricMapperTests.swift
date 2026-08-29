import Foundation
import Testing

@testable import CareLoop

/// 化验单条目映射：名称识别、脏值解析、美制单位换算、日期与整体管线。
struct LabMetricMapperTests {
    @Test func chineseAndEnglishNames() {
        #expect(LabMetricMapper.metricType(forName: "糖化血红蛋白") == .hba1c)
        #expect(LabMetricMapper.metricType(forName: "糖化血红蛋白(HbA1c)") == .hba1c)
        #expect(LabMetricMapper.metricType(forName: "HbA1c") == .hba1c)
        #expect(LabMetricMapper.metricType(forName: "总胆固醇") == .totalCholesterol)
        #expect(LabMetricMapper.metricType(forName: "血清总胆固醇 (TC)") == .totalCholesterol)
        #expect(LabMetricMapper.metricType(forName: "低密度脂蛋白胆固醇") == .ldlCholesterol)
        #expect(LabMetricMapper.metricType(forName: "LDL-C") == .ldlCholesterol)
        // "高密度脂蛋白胆固醇"包含"胆固醇"，但最长同义词命中必须优先
        #expect(LabMetricMapper.metricType(forName: "高密度脂蛋白胆固醇") == .hdlCholesterol)
        #expect(LabMetricMapper.metricType(forName: "HDL") == .hdlCholesterol)
        #expect(LabMetricMapper.metricType(forName: "甘油三酯") == .triglycerides)
        #expect(LabMetricMapper.metricType(forName: "TG") == .triglycerides)
        // 非目标化验项不映射
        #expect(LabMetricMapper.metricType(forName: "白细胞计数") == nil)
        #expect(LabMetricMapper.metricType(forName: "血常规") == nil)
    }

    @Test func parsesDirtyValues() {
        #expect(LabMetricMapper.parseValue("5.8") == 5.8)
        #expect(LabMetricMapper.parseValue("≥7.8") == 7.8)
        #expect(LabMetricMapper.parseValue("<3.9") == 3.9)
        #expect(LabMetricMapper.parseValue("1,200") == 1200)
        #expect(LabMetricMapper.parseValue("5.8 mmol/L") == 5.8)
        #expect(LabMetricMapper.parseValue("未见异常") == nil)
    }

    @Test func unitConversion() {
        // 胆固醇 mg/dL → mmol/L：÷38.67
        let tc = LabMetricMapper.normalizedValue(value: 200, unit: "mg/dL", type: .totalCholesterol)
        #expect(abs(tc - 200.0 / 38.67) < 0.0001)
        // 甘油三酯 mg/dL → mmol/L：÷88.57
        let tg = LabMetricMapper.normalizedValue(value: 200, unit: "mg/dl", type: .triglycerides)
        #expect(abs(tg - 200.0 / 88.57) < 0.0001)
        // hba1c 本身是 %，mmol/L 输入原样返回
        #expect(LabMetricMapper.normalizedValue(value: 6.5, unit: "%", type: .hba1c) == 6.5)
        #expect(LabMetricMapper.normalizedValue(value: 4.6, unit: "mmol/L", type: .totalCholesterol) == 4.6)
        #expect(LabMetricMapper.normalizedValue(value: 4.6, unit: nil, type: .totalCholesterol) == 4.6)
    }

    @Test func dateParsing() {
        let cal = Calendar.current
        let parsed = LabMetricMapper.parseDate("2026-08-01")
        #expect(parsed != nil)
        #expect(cal.dateComponents([.year, .month, .day], from: parsed!) == DateComponents(year: 2026, month: 8, day: 1))
        #expect(LabMetricMapper.parseDate("2026/08/01") != nil)
        #expect(LabMetricMapper.parseDate("不合法") == nil)
        #expect(LabMetricMapper.parseDate(nil) == nil)
    }

    @Test func mapsMedicalDocToMetrics() {
        let doc = MedicalDocResult(
            docType: "检验报告",
            title: nil,
            takenAt: "2026-08-01",
            diagnoses: [],
            labValues: [
                LabValueItem(name: "糖化血红蛋白", value: "6.4", unit: "%", reference: nil, flag: "H"),
                LabValueItem(name: "总胆固醇", value: "240", unit: "mg/dL", reference: nil, flag: nil),
                LabValueItem(name: "白细胞", value: "6.0", unit: nil, reference: nil, flag: nil),
                LabValueItem(name: "低密度脂蛋白", value: "溶血", unit: nil, reference: nil, flag: nil),
            ],
            medications: [],
            recommendations: [],
            followUpHint: nil,
            followUpDate: nil,
            followUpDepartment: nil,
            summary: ""
        )
        let fallback = Date(timeIntervalSince1970: 0)
        let metrics = LabMetricMapper.metrics(from: doc, fallbackDate: fallback, sourceName: LabMetricMapper.ocrSourceName)

        // 白细胞不在映射表、低密度脂蛋白值解析失败 → 均跳过
        #expect(metrics.count == 2)
        let hba1c = metrics.first { $0.type == .hba1c }
        #expect(hba1c?.value == 6.4)
        #expect(hba1c?.sourceName == LabMetricMapper.ocrSourceName)
        let cal = Calendar.current
        #expect(cal.isDate(hba1c!.date, inSameDayAs: LabMetricMapper.parseDate("2026-08-01")!))
        let tc = metrics.first { $0.type == .totalCholesterol }
        #expect(tc.map { abs($0.value - 240.0 / 38.67) < 0.0001 } == true)
    }

    @Test func fallbackDateWhenTakenAtMissing() {
        let doc = MedicalDocResult(
            docType: "手动录入",
            title: nil,
            takenAt: nil,
            diagnoses: [],
            labValues: [LabValueItem(name: "甘油三酯", value: "1.9", unit: nil, reference: nil, flag: nil)],
            medications: [],
            recommendations: [],
            followUpHint: nil,
            followUpDate: nil,
            followUpDepartment: nil,
            summary: ""
        )
        let fallback = Date(timeIntervalSince1970: 1_756_000_000)
        let metrics = LabMetricMapper.metrics(from: doc, fallbackDate: fallback, sourceName: LabMetricMapper.manualSourceName)
        #expect(metrics.count == 1)
        #expect(metrics.first?.value == 1.9)
        #expect(metrics.first?.date == fallback)
    }
}
