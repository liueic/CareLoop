import Foundation
import HealthKit
import Testing

@testable import CareLoop

/// 数据来源契约：锁定 MetricType 分类、HealthKitProvider 支持集、授权集合与 Mock 的对齐关系。
/// 此前 Mock 返回全部 26 种而真实 Provider 只实现 12 种的漂移，正是因为缺少这层契约。
struct MetricTypeContractTests {
    @Test func dataSourcePartitionsAllCases() {
        let healthKit = MetricType.healthKitTypes
        let labEntry = MetricType.labEntryTypes
        #expect(healthKit.isDisjoint(with: labEntry))
        #expect(healthKit.union(labEntry) == Set(MetricType.allCases))
        #expect(labEntry == Set([
            .hba1c, .totalCholesterol, .ldlCholesterol, .hdlCholesterol, .triglycerides,
        ]))
    }

    @Test func providerSupportsExactlyHealthKitTypes() {
        #expect(HealthKitProvider.supportedMetricTypes == MetricType.healthKitTypes)
        #expect(HealthKitProvider.supportedMetricTypes.count == 21)
    }

    @Test func queriedIdentifiersAreAuthorized() {
        let readTypes = HealthKitProvider.readTypes
        for id in HealthKitProvider.queriedQuantityIdentifiers {
            guard let type = HKQuantityType.quantityType(forIdentifier: id) else {
                Issue.record("无法构造 quantity 类型: \(id.rawValue)")
                continue
            }
            #expect(readTypes.contains(type), "readTypes 缺少 \(id.rawValue)")
        }
        #expect(readTypes.contains(HKCategoryType(.sleepAnalysis)))
        #expect(readTypes.contains(HKObjectType.workoutType()))
    }

    /// Mock 有意为全部指标提供演示剧本（demo 体验），这里显式锁定该意图，
    /// 防止有人"对齐 Mock 与真实"时误删演示数据。
    @Test func mockProvidesAllTypesForDemo() async {
        let mock = MockHealthProvider(referenceDate: Date())
        for type in MetricType.allCases {
            let series = await mock.dailySeries(type, days: 7)
            #expect(!series.isEmpty, "Mock 应为 \(type.displayName) 提供演示数据")
        }
    }
}
