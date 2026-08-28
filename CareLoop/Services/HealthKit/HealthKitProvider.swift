import Foundation
import HealthKit

final class HealthKitProvider: HealthDataProviding, @unchecked Sendable {
    let sourceLabel = "Apple Health"
    private let store = HKHealthStore()

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
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
                unit: HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter()),
                type: type
            )
        case .oxygenSaturation:
            return await statistics(.oxygenSaturation, options: .discreteAverage, start: start, end: end, unit: .percent(), type: type)
        case .sleepHours:
            return await sleepHours(start: start, end: end)
        case .workoutMinutes:
            return await workoutMinutes(start: start, end: end)
        case .vo2max, .respiratoryRate, .wristTemperatureDeviation, .cgmTIR, .cgmMean,
             .sleepDeepPercent, .sleepREMPercent, .afBurden, .hba1c, .totalCholesterol,
             .ldlCholesterol, .hdlCholesterol, .triglycerides, .waistCircumference:
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

    private func sleepHours(start: Date, end: Date) async -> HealthMetric? {
        let type = HKCategoryType(.sleepAnalysis)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)]
        )
        guard let samples = try? await descriptor.result(for: store) else { return nil }
        var seconds: TimeInterval = 0
        for sample in samples {
            let value = HKCategoryValueSleepAnalysis(rawValue: sample.value)
            if value == .asleepUnspecified || value == .asleepCore || value == .asleepDeep || value == .asleepREM || value == .asleep {
                seconds += sample.endDate.timeIntervalSince(sample.startDate)
            }
        }
        guard seconds > 0 else { return nil }
        return HealthMetric(type: .sleepHours, value: seconds / 3600, date: start, sourceName: sourceLabel)
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

    private static var readTypes: Set<HKObjectType> {
        var set: Set<HKObjectType> = [
            HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!,
            HKObjectType.characteristicType(forIdentifier: .biologicalSex)!,
            HKObjectType.characteristicType(forIdentifier: .bloodType)!,
            HKObjectType.characteristicType(forIdentifier: .wheelchairUse)!,
            HKObjectType.workoutType(),
            HKCategoryType(.sleepAnalysis),
        ]
        let quantities: [HKQuantityTypeIdentifier] = [
            .stepCount, .restingHeartRate, .heartRate, .heartRateVariabilitySDNN,
            .activeEnergyBurned, .bodyMass, .height, .bloodPressureSystolic,
            .bloodPressureDiastolic, .bloodGlucose, .oxygenSaturation,
        ]
        for id in quantities {
            if let type = HKQuantityType.quantityType(forIdentifier: id) {
                set.insert(type)
            }
        }
        return set
    }
}
