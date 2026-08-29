import Foundation
import SwiftData

/// 化验指标的本地存取层：把手帐里 `kind == .medicalDoc` 的条目
/// （化验单 OCR 识别结果与手动录入共用同一 `MedicalDocResult` 结构）
/// 映射为 HealthMetric，供今日管线与今日页在 HealthKit 无来源时兜底。
@MainActor
enum LabMetricStore {
    /// 化验指标的有效回看窗口：hba1c 反映近 2–3 个月血糖水平，血脂复查周期通常 ≥ 1 个月。
    static let lookbackDays = 180

    /// 各化验指标的最近一次值（窗口内、多份化验单取最新）。
    static func latestLabMetrics(context: ModelContext, now: Date = Date()) -> [MetricType: HealthMetric] {
        var latest: [MetricType: HealthMetric] = [:]
        for entry in labEntries(context: context) {
            for metric in mappedMetrics(from: entry) where isWithinLookback(metric.date, now: now) {
                if metric.date > (latest[metric.type]?.date ?? .distantPast) {
                    latest[metric.type] = metric
                }
            }
        }
        return latest
    }

    /// 某化验指标在窗口内的日序列（同一天多条取时间最新的一条），供临床引擎 history。
    static func historySeries(type: MetricType, context: ModelContext, now: Date = Date()) -> [DailyMetricPoint] {
        let cal = Calendar.current
        var latestTimeByDay: [Date: Date] = [:]
        var pointByDay: [Date: DailyMetricPoint] = [:]
        for entry in labEntries(context: context) {
            for metric in mappedMetrics(from: entry)
            where metric.type == type && isWithinLookback(metric.date, now: now) {
                let day = cal.startOfDay(for: metric.date)
                if let knownTime = latestTimeByDay[day], knownTime >= metric.date { continue }
                latestTimeByDay[day] = metric.date
                pointByDay[day] = DailyMetricPoint(day: day, value: metric.value, sourceName: metric.sourceName)
            }
        }
        return pointByDay.values.sorted { $0.day < $1.day }
    }

    private static func labEntries(context: ModelContext) -> [DailyLogEntry] {
        let entries = (try? context.fetch(FetchDescriptor<DailyLogEntry>())) ?? []
        return entries.filter { $0.kind == .medicalDoc }
    }

    private static func mappedMetrics(from entry: DailyLogEntry) -> [HealthMetric] {
        guard let doc = entry.medicalDoc else { return [] }
        let source = doc.docType == LabMetricMapper.manualDocType
            ? LabMetricMapper.manualSourceName
            : LabMetricMapper.ocrSourceName
        return LabMetricMapper.metrics(from: doc, fallbackDate: entry.createdAt, sourceName: source)
    }

    private static func isWithinLookback(_ date: Date, now: Date) -> Bool {
        date <= now && date > now.addingTimeInterval(-Double(lookbackDays) * 86400)
    }
}
