import Foundation
import HealthKit

final class HealthKitProvider: HealthDataProviding, @unchecked Sendable {
    let sourceLabel = "Apple Health"
    private let store = HKHealthStore()

    /// 能从 HealthKit 读出（直接统计或派生计算）的指标集合。
    /// 与 `MetricType.healthKitTypes` 对齐，由契约测试锁定；化验类指标（hba1c、血脂）走录入路径。
    static let supportedMetricTypes: Set<MetricType> = MetricType.healthKitTypes

    /// metric(_:on:) 与 characteristics() 实际查询的 quantity 标识符，
    /// 契约测试据此断言全部包含在 readTypes 授权集合内，防止"查了没授权的类型"。
    static let queriedQuantityIdentifiers: Set<HKQuantityTypeIdentifier> = [
        .stepCount, .activeEnergyBurned, .restingHeartRate, .heartRate,
        .heartRateVariabilitySDNN, .bodyMass, .height, .bloodPressureSystolic,
        .bloodPressureDiastolic, .bloodGlucose, .oxygenSaturation,
        .vo2Max, .respiratoryRate, .atrialFibrillationBurden,
        .appleSleepingWristTemperature, .waistCircumference,
    ]

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    /// 用户尚未对健康权限做出选择（含从未弹窗）时为 true。
    /// 注意：已拒绝时这里也为 false——HealthKit 不区分"拒绝"与"已授权"，
    /// 需结合查询结果为空来引导用户去系统设置。
    func authorizationNeedsRequest() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        // SDK 把 async 版本重命名为 statusForAuthorizationRequest(toShare:read:)。
        let status = try? await store.statusForAuthorizationRequest(toShare: [], read: Self.readTypes)
        return status == .shouldRequest
    }

    func characteristics() async -> CharacteristicSnapshot {
        var snap = CharacteristicSnapshot()
        if let birth = try? store.dateOfBirthComponents().date {
            snap.birthDate = birth
        }
        if let sex = try? store.biologicalSex() {
            switch sex.biologicalSex {
            case .female: snap.biologicalSex = .female
            case .male: snap.biologicalSex = .male
            case .other: snap.biologicalSex = .other
            default: snap.biologicalSex = .unspecified
            }
        }
        if let blood = try? store.bloodType() {
            snap.bloodType = mapBlood(blood.bloodType)
        }
        if let chair = try? store.wheelchairUse() {
            switch chair.wheelchairUse {
            case .yes: snap.wheelchairUse = .yes
            case .no: snap.wheelchairUse = .no
            default: snap.wheelchairUse = .unspecified
            }
        }
        if let height = await latestQuantity(.height) {
            snap.heightCM = height.doubleValue(for: .meterUnit(with: .centi))
        }
        if let mass = await latestQuantity(.bodyMass) {
            snap.weightKG = mass.doubleValue(for: .gramUnit(with: .kilo))
        }
        return snap
    }

    func metric(_ type: MetricType, on day: Date) async -> HealthMetric? {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? day
        switch type {
        case .stepCount:
            return await statistics(.stepCount, options: .cumulativeSum, start: start, end: end, unit: .count(), type: type)
        case .activeEnergy:
            return await statistics(.activeEnergyBurned, options: .cumulativeSum, start: start, end: end, unit: .kilocalorie(), type: type)
        case .restingHeartRate:
            return await statistics(.restingHeartRate, options: .discreteAverage, start: start, end: end, unit: .count().unitDivided(by: .minute()), type: type)
        case .heartRate:
            return await statistics(.heartRate, options: .discreteAverage, start: start, end: end, unit: .count().unitDivided(by: .minute()), type: type)
        case .hrvSDNN:
            return await statistics(.heartRateVariabilitySDNN, options: .discreteAverage, start: start, end: end, unit: .secondUnit(with: .milli), type: type)
        case .bodyMass:
            return await statistics(.bodyMass, options: .discreteAverage, start: start, end: end, unit: .gramUnit(with: .kilo), type: type)
        case .bloodPressureSystolic:
            return await statistics(.bloodPressureSystolic, options: .discreteAverage, start: start, end: end, unit: .millimeterOfMercury(), type: type)
        case .bloodPressureDiastolic:
            return await statistics(.bloodPressureDiastolic, options: .discreteAverage, start: start, end: end, unit: .millimeterOfMercury(), type: type)
        case .bloodGlucose:
            return await statistics(
                .bloodGlucose,
                options: .discreteAverage,
                start: start,
                end: end,
                unit: Self.glucoseUnit,
                type: type
            )
        case .oxygenSaturation:
            return await statistics(.oxygenSaturation, options: .discreteAverage, start: start, end: end, unit: .percent(), type: type)
        case .vo2max:
            return await statistics(.vo2Max, options: .discreteAverage, start: start, end: end, unit: Self.vo2MaxUnit, type: type)
        case .respiratoryRate:
            return await statistics(.respiratoryRate, options: .discreteAverage, start: start, end: end, unit: .count().unitDivided(by: .minute()), type: type)
        case .wristTemperatureDeviation:
            return await statistics(.appleSleepingWristTemperature, options: .discreteAverage, start: start, end: end, unit: .degreeCelsius(), type: type)
        case .afBurden:
            return await statistics(.atrialFibrillationBurden, options: .discreteAverage, start: start, end: end, unit: .percent(), type: type)
        case .waistCircumference:
            return await statistics(.waistCircumference, options: .discreteAverage, start: start, end: end, unit: .meterUnit(with: .centi), type: type)
        case .sleepHours:
            guard let summary = await sleepSummary(start: start, end: end) else { return nil }
            return HealthMetric(type: type, value: summary.totalAsleepHours, date: start, sourceName: sourceLabel)
        case .sleepDeepPercent:
            guard let percent = await sleepSummary(start: start, end: end)?.deepPercent else { return nil }
            return HealthMetric(type: type, value: percent, date: start, sourceName: sourceLabel)
        case .sleepREMPercent:
            guard let percent = await sleepSummary(start: start, end: end)?.remPercent else { return nil }
            return HealthMetric(type: type, value: percent, date: start, sourceName: sourceLabel)
        case .cgmTIR, .cgmMean:
            return await glucoseMetric(type, start: start, end: end)
        case .workoutMinutes:
            return await workoutMinutes(start: start, end: end)
        case .hba1c, .totalCholesterol, .ldlCholesterol, .hdlCholesterol, .triglycerides:
            // HealthKit 公开 API 没有这些化验类型（仅存在于美区 Health Records），
            // 由 LabMetricStore 的化验单 OCR / 手动录入路径补齐。
            return nil
        }
    }

    func dailySeries(_ type: MetricType, days: Int) async -> [DailyMetricPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var points: [DailyMetricPoint] = []
        for offset in (0..<days).reversed() {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            if let metric = await metric(type, on: day) {
                points.append(DailyMetricPoint(day: day, value: metric.value, sourceName: metric.sourceName))
            }
        }
        return points
    }

    private func statistics(
        _ identifier: HKQuantityTypeIdentifier,
        options: HKStatisticsOptions,
        start: Date,
        end: Date,
        unit: HKUnit,
        type: MetricType
    ) async -> HealthMetric? {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: HKSamplePredicate<HKQuantitySample>.quantitySample(type: quantityType, predicate: predicate),
            options: options
        )
        guard let stats = try? await descriptor.result(for: store) else { return nil }
        let quantity: HKQuantity?
        if options.contains(.cumulativeSum) {
            quantity = stats.sumQuantity()
        } else {
            quantity = stats.averageQuantity()
        }
        guard let quantity else { return nil }
        let source = stats.sources?.first?.name ?? sourceLabel
        return HealthMetric(type: type, value: quantity.doubleValue(for: unit), date: start, sourceName: source)
    }

    // MARK: - 派生指标

    /// 拉取一天的全部睡眠样本，跨来源合并后得到总时长与分期占比。
    private func sleepSummary(start: Date, end: Date) async -> SleepAggregator.Summary? {
        let type = HKCategoryType(.sleepAnalysis)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)]
        )
        guard let samples = try? await descriptor.result(for: store) else { return nil }
        let mapped = samples.compactMap { sample -> SleepAggregator.Sample? in
            guard let stage = Self.mapSleepStage(HKCategoryValueSleepAnalysis(rawValue: sample.value)) else { return nil }
            return SleepAggregator.Sample(stage: stage, start: sample.startDate, end: sample.endDate)
        }
        return SleepAggregator.evaluate(mapped)
    }

    private static func mapSleepStage(_ value: HKCategoryValueSleepAnalysis?) -> SleepAggregator.Stage? {
        switch value {
        case .asleepUnspecified, .asleep: .asleepUnspecified
        case .asleepCore: .asleepCore
        case .asleepDeep: .asleepDeep
        case .asleepREM: .asleepREM
        case .awake: .awake
        case .inBed: .inBed
        default: nil
        }
    }

    /// 从当天的血糖读数聚合 CGM TIR / 均值；读数密度不足（指尖血）返回 nil。
    private func glucoseMetric(_ type: MetricType, start: Date, end: Date) async -> HealthMetric? {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: .bloodGlucose) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: quantityType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)]
        )
        guard let samples = try? await descriptor.result(for: store), !samples.isEmpty else { return nil }
        let values = samples.map { $0.quantity.doubleValue(for: Self.glucoseUnit) }
        guard let summary = GlucoseAggregator.evaluate(valuesMmolL: values) else { return nil }
        let source = samples.first?.sourceRevision.source.name ?? sourceLabel
        switch type {
        case .cgmTIR:
            return HealthMetric(type: type, value: summary.tirPercent, date: start, sourceName: source)
        case .cgmMean:
            return HealthMetric(type: type, value: summary.meanMmolL, date: start, sourceName: source)
        default:
            return nil
        }
    }

    private func workoutMinutes(start: Date, end: Date) async -> HealthMetric? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)]
        )
        guard let workouts = try? await descriptor.result(for: store) else { return nil }
        let minutes = workouts.reduce(0.0) { $0 + $1.duration / 60 }
        guard minutes > 0 else { return nil }
        return HealthMetric(type: .workoutMinutes, value: minutes, date: start, sourceName: sourceLabel)
    }

    private func latestQuantity(_ id: HKQuantityTypeIdentifier) async -> HKQuantity? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        let samples = try? await descriptor.result(for: store)
        return samples?.first?.quantity
    }

    private func mapBlood(_ type: HKBloodType) -> BloodType {
        switch type {
        case .aPositive: .aPos
        case .aNegative: .aNeg
        case .bPositive: .bPos
        case .bNegative: .bNeg
        case .abPositive: .abPos
        case .abNegative: .abNeg
        case .oPositive: .oPos
        case .oNegative: .oNeg
        default: .unknown
        }
    }

    // MARK: - 单位与授权类型

    private static let glucoseUnit = HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter())
    private static let vo2MaxUnit = HKUnit.literUnit(with: .milli)
        .unitDivided(by: .gramUnit(with: .kilo))
        .unitDivided(by: .minute())

    static var readTypes: Set<HKObjectType> {
        var set: Set<HKObjectType> = [
            HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!,
            HKObjectType.characteristicType(forIdentifier: .biologicalSex)!,
            HKObjectType.characteristicType(forIdentifier: .bloodType)!,
            HKObjectType.characteristicType(forIdentifier: .wheelchairUse)!,
            HKObjectType.workoutType(),
            HKCategoryType(.sleepAnalysis),
        ]
        for id in queriedQuantityIdentifiers {
            if let type = HKQuantityType.quantityType(forIdentifier: id) {
                set.insert(type)
            }
        }
        return set
    }
}
