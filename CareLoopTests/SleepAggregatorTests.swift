import Foundation
import Testing

@testable import CareLoop

/// 睡眠聚合：多来源重叠去重、不相邻区间相加、阶段桶隔离。
struct SleepAggregatorTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func overlappingSamplesFromMultipleSourcesCountOnce() {
        // Watch 记录 0–8 点，第三方 App 记录 1–9 点 → 合并后 0–9 点 = 9 小时（旧逻辑会计成 16）
        let summary = SleepAggregator.evaluate([
            .init(stage: .asleepCore, start: base, end: base.addingTimeInterval(8 * 3600)),
            .init(stage: .asleepUnspecified, start: base.addingTimeInterval(3600), end: base.addingTimeInterval(9 * 3600)),
        ])
        #expect((summary?.totalAsleepHours ?? 0) == 9)
    }

    @Test func nestedIntervalsCountOnce() {
        // 第三方 App 的深睡段嵌套在 Watch 的 core 段内：总 asleep 不变
        let summary = SleepAggregator.evaluate([
            .init(stage: .asleepCore, start: base, end: base.addingTimeInterval(8 * 3600)),
            .init(stage: .asleepDeep, start: base.addingTimeInterval(2 * 3600), end: base.addingTimeInterval(3 * 3600)),
        ])
        #expect(summary?.totalAsleepHours == 8)
        #expect(summary?.deepHours == 1)
    }

    @Test func disjointIntervalsAddUp() {
        // 夜间 7 小时 + 午睡 1 小时（REM 段）
        let summary = SleepAggregator.evaluate([
            .init(stage: .asleepCore, start: base, end: base.addingTimeInterval(7 * 3600)),
            .init(stage: .asleepREM, start: base.addingTimeInterval(10 * 3600), end: base.addingTimeInterval(11 * 3600)),
        ])
        #expect(summary?.totalAsleepHours == 8)
        #expect(summary?.remHours == 1)
    }

    @Test func awakeAndInBedExcluded() {
        let summary = SleepAggregator.evaluate([
            .init(stage: .inBed, start: base, end: base.addingTimeInterval(9 * 3600)),
            .init(stage: .awake, start: base.addingTimeInterval(4 * 3600), end: base.addingTimeInterval(4 * 3600 + 1800)),
            .init(stage: .asleepCore, start: base, end: base.addingTimeInterval(9 * 3600)),
        ])
        #expect(summary?.totalAsleepHours == 9)
    }

    @Test func deepAndREMPercentages() {
        let summary = SleepAggregator.evaluate([
            .init(stage: .asleepCore, start: base, end: base.addingTimeInterval(5 * 3600)),
            .init(stage: .asleepDeep, start: base.addingTimeInterval(5 * 3600), end: base.addingTimeInterval(7 * 3600)),
            .init(stage: .asleepREM, start: base.addingTimeInterval(7 * 3600), end: base.addingTimeInterval(8 * 3600)),
        ])
        #expect(summary?.totalAsleepHours == 8)
        #expect(summary?.deepHours == 2)
        #expect(summary?.remHours == 1)
        #expect(summary?.deepPercent == 25)
        #expect(summary?.remPercent == 12.5)
    }

    @Test func noStagedDataYieldsNilPercent() {
        // 旧设备只有 asleepUnspecified，无分期 → 占比为 nil 而非 0
        let summary = SleepAggregator.evaluate([
            .init(stage: .asleepUnspecified, start: base, end: base.addingTimeInterval(7 * 3600)),
        ])
        #expect(summary?.totalAsleepHours == 7)
        #expect(summary?.deepPercent == nil)
        #expect(summary?.remPercent == nil)
    }

    @Test func emptyOrInvalidSamplesReturnNil() {
        #expect(SleepAggregator.evaluate([]) == nil)
        #expect(SleepAggregator.evaluate([.init(stage: .asleepCore, start: base, end: base)]) == nil)
    }
}
