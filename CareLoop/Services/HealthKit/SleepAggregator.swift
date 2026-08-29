import Foundation

/// 睡眠样本聚合器（纯函数，不依赖 HealthKit，可单测）。
///
/// Apple Watch、iPhone 与第三方睡眠 App 常对同一晚睡眠各自记录 asleep 段，
/// 直接逐样本累加会重复计数。这里按阶段桶做跨来源的**重叠区间合并**：
/// 多来源重叠部分只计一次，真实不连续的入睡段（午睡等）正常相加。
enum SleepAggregator {
    /// 与 HKCategoryValueSleepAnalysis 对应的值桶（仅保留需要的子集）。
    enum Stage: Equatable, Sendable {
        case asleepUnspecified
        case asleepCore
        case asleepDeep
        case asleepREM
        case awake
        case inBed

        var countsAsAsleep: Bool {
            switch self {
            case .asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM: true
            case .awake, .inBed: false
            }
        }
    }

    struct Sample: Equatable, Sendable {
        var stage: Stage
        var start: Date
        var end: Date
    }

    struct Summary: Equatable, Sendable {
        /// 合并后的总 asleep 时长（小时）。
        var totalAsleepHours: Double
        /// 合并后的深睡时长（小时）。
        var deepHours: Double
        /// 合并后的 REM 时长（小时）。
        var remHours: Double

        /// 深睡占总 asleep 的百分比；无分期数据（旧设备只有 asleepUnspecified）时为 nil。
        var deepPercent: Double? {
            guard totalAsleepHours > 0, deepHours > 0 else { return nil }
            return deepHours / totalAsleepHours * 100
        }

        var remPercent: Double? {
            guard totalAsleepHours > 0, remHours > 0 else { return nil }
            return remHours / totalAsleepHours * 100
        }
    }

    static func evaluate(_ samples: [Sample]) -> Summary? {
        let valid = samples.filter { $0.end > $0.start }
        let asleep = mergedDuration(valid.filter { $0.stage.countsAsAsleep })
        guard asleep > 0 else { return nil }
        return Summary(
            totalAsleepHours: asleep / 3600,
            deepHours: mergedDuration(valid.filter { $0.stage == .asleepDeep }) / 3600,
            remHours: mergedDuration(valid.filter { $0.stage == .asleepREM }) / 3600
        )
    }

    /// 排序 + 扫描合并重叠（含端点相接）的区间，返回总时长（秒）。
    private static func mergedDuration(_ intervals: [Sample]) -> TimeInterval {
        guard !intervals.isEmpty else { return 0 }
        let sorted = intervals.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var total: TimeInterval = 0
        var currentStart = sorted[0].start
        var currentEnd = sorted[0].end
        for interval in sorted.dropFirst() {
            if interval.start <= currentEnd {
                currentEnd = max(currentEnd, interval.end)
            } else {
                total += currentEnd.timeIntervalSince(currentStart)
                currentStart = interval.start
                currentEnd = interval.end
            }
        }
        return total + currentEnd.timeIntervalSince(currentStart)
    }
}
