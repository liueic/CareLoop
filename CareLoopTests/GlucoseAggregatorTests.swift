import Foundation
import Testing

@testable import CareLoop

/// CGM 血糖日聚合：TIR 区间边界、均值与密度护栏。
struct GlucoseAggregatorTests {
    @Test func belowDensityGuardReturnsNil() {
        // 指尖血：一天 3 个读数不足以定义 TIR
        #expect(GlucoseAggregator.evaluate(valuesMmolL: [5.5, 6.1, 7.2]) == nil)
        #expect(GlucoseAggregator.evaluate(valuesMmolL: []) == nil)
    }

    @Test func exactlyAtGuardSucceeds() {
        let summary = GlucoseAggregator.evaluate(valuesMmolL: Array(repeating: 5.5, count: 8))
        #expect(summary != nil)
        #expect(summary?.sampleCount == 8)
    }

    @Test func boundariesAreInclusive() {
        // 3.9 与 10.0 恰好在界内（70–180 mg/dL 含边界）
        let summary = GlucoseAggregator.evaluate(valuesMmolL: [3.9, 10.0] + Array(repeating: 5.5, count: 6))
        #expect(summary?.tirPercent == 100)
    }

    @Test func justOutsideBoundaryCountsOutOfRange() {
        let summary = GlucoseAggregator.evaluate(valuesMmolL: [3.89, 10.01] + Array(repeating: 5.0, count: 6))
        #expect(summary?.tirPercent == 75)
    }

    @Test func meanComputed() {
        let summary = GlucoseAggregator.evaluate(valuesMmolL: [4.0, 6.0] + Array(repeating: 5.0, count: 6))
        #expect(summary?.meanMmolL == 5)
    }
}
