import Foundation
import SwiftData

/// BaselineSnapshot 的写入策略：表当前为纯写入（无任何读取方），
/// 每次刷新先全量清空再重建，避免逐次追加导致无限增长；
/// 空序列（该指标当天完全无数据）不落快照。
@MainActor
enum BaselineSnapshotStore {
    struct Entry {
        var result: BaselineResult
        var sampleCount: Int

        init(result: BaselineResult, sampleCount: Int) {
            self.result = result
            self.sampleCount = sampleCount
        }
    }

    static func replaceToday(context: ModelContext, entries: [Entry]) {
        let existing = (try? context.fetch(FetchDescriptor<BaselineSnapshot>())) ?? []
        for old in existing {
            context.delete(old)
        }
        for entry in entries where entry.sampleCount > 0 {
            context.insert(
                BaselineSnapshot(
                    metricType: entry.result.metricType,
                    windowDays: entry.result.windowDays,
                    mean: entry.result.mean,
                    stdDev: entry.result.stdDev
                )
            )
        }
    }
}
