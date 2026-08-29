import Foundation
import SwiftData
import Testing

@testable import CareLoop

/// BaselineSnapshot 替换式写入：旧行全删、空序列跳过、重复刷新不增长。
struct BaselineSnapshotStoreTests {
    @MainActor
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: BaselineSnapshot.self, configurations: config)
        return ModelContext(container)
    }

    private func entry(_ type: MetricType, mean: Double, sampleCount: Int = 14) -> BaselineSnapshotStore.Entry {
        BaselineSnapshotStore.Entry(
            result: BaselineResult(
                metricType: type,
                windowDays: 14,
                mean: mean,
                stdDev: 1,
                today: nil,
                zScore: nil,
                deviation: false,
                persistent: false,
                recentZScores: []
            ),
            sampleCount: sampleCount
        )
    }

    @Test
    @MainActor
    func replacesOldRowsAndSkipsEmptySeries() throws {
        let context = try makeContext()
        // 模拟旧行为累积下来的历史残留
        context.insert(BaselineSnapshot(metricType: .stepCount, windowDays: 14, mean: 5000, stdDev: 800))
        context.insert(BaselineSnapshot(metricType: .heartRate, windowDays: 14, mean: 70, stdDev: 5))
        try context.save()

        BaselineSnapshotStore.replaceToday(context: context, entries: [
            entry(.stepCount, mean: 6000),
            entry(.sleepHours, mean: 0, sampleCount: 0),
        ])
        try context.save()

        let rows = try context.fetch(FetchDescriptor<BaselineSnapshot>())
        #expect(rows.count == 1)
        #expect(rows.first?.metricType == .stepCount)
        #expect(abs((rows.first?.mean ?? 0) - 6000) < 0.001)
    }

    @Test
    @MainActor
    func repeatedRefreshDoesNotGrow() throws {
        let context = try makeContext()
        let entries = [entry(.restingHeartRate, mean: 61), entry(.heartRate, mean: 68)]
        for _ in 0..<5 {
            BaselineSnapshotStore.replaceToday(context: context, entries: entries)
            try context.save()
        }
        let rows = try context.fetch(FetchDescriptor<BaselineSnapshot>())
        #expect(rows.count == 2)
    }
}
