import Foundation
import SwiftData
import SwiftUI
import UIKit

@Observable
@MainActor
final class AppEnvironment {
    let container: ModelContainer
    var demoMode: Bool {
        didSet {
            UserDefaults.standard.set(demoMode, forKey: "careloop.demoMode")
            refreshProvider()
        }
    }
    var healthProvider: any HealthDataProviding
    var activeSelection: ActiveModelSelection {
        didSet { persistSelection() }
    }
    var lastAdvice: AdvicePipelineOutput?
    var isRefreshing = false
    var recipes: [Recipe]
    var exercises: [ExerciseItem]
    var rules: GuidelineRules
    var dietRules: DietGuidelineRules

    init() {
        let schema = Schema([
            UserProfile.self,
            DailyLogEntry.self,
            Medication.self,
            MedicationIntake.self,
            FollowUp.self,
            HospitalReport.self,
            AlertRecord.self,
            BaselineSnapshot.self,
            LLMProviderConfig.self,
            ModelCatalogEntry.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            container = try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
        }
        let simulatorDemo: Bool
        #if targetEnvironment(simulator)
        simulatorDemo = true
        #else
        simulatorDemo = false
        #endif
        demoMode = UserDefaults.standard.object(forKey: "careloop.demoMode") as? Bool ?? simulatorDemo
        healthProvider = MockHealthProvider()
        if let data = UserDefaults.standard.data(forKey: ActiveModelSelection.storageKey),
           let saved = try? JSONDecoder().decode(ActiveModelSelection.self, from: data) {
            activeSelection = saved
        } else {
            activeSelection = ActiveModelSelection(providerKey: "deepseek", modelID: "deepseek-chat")
        }
        recipes = ContentLibrary.loadRecipes()
        exercises = ContentLibrary.loadExercises()
        rules = GuidelineRules.load()
        dietRules = DietGuidelineCompiler.mergedWithClinicalAdvice(DietGuidelineRules.load())
        DietSpotlightIndexer.reindex(recipes: recipes, dietRules: dietRules)
        refreshProvider()
        ProviderManager(context: container.mainContext).bootstrapIfNeeded()
        DemoSeeder.seedIfNeeded(context: container.mainContext)
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-uitest-fresh-onboarding") {
            let profile = profile()
            profile.onboardingCompleted = false
            try? container.mainContext.save()
        } else if args.contains("-uitest-skip-onboarding") {
            let profile = profile()
            DemoSeeder.applyDemoPersona(profile)
            profile.onboardingCompleted = true
            try? container.mainContext.save()
        }
    }

    var context: ModelContext { container.mainContext }

    func refreshProvider() {
        if demoMode {
            healthProvider = MockHealthProvider()
        } else if HealthKitRuntime.isAvailable {
            healthProvider = HealthKitProvider()
        } else {
            healthProvider = MockHealthProvider()
        }
    }

    func currentLLM() -> any LLMProviding {
        ProviderManager(context: context).makeLLM(selection: activeSelection)
    }

    func profile() -> UserProfile {
        let items = (try? context.fetch(FetchDescriptor<UserProfile>())) ?? []
        if let existing = items.first { return existing }
        let created = UserProfile()
        context.insert(created)
        try? context.save()
        return created
    }

    func refreshTodayPipeline() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let profile = profile()
        let tags = profile.desensitizedTags()
        let types: [MetricType] = [
            .sleepHours, .restingHeartRate, .stepCount, .heartRate,
            .bloodPressureSystolic, .bloodPressureDiastolic, .bloodGlucose,
            .oxygenSaturation, .hrvSDNN, .vo2max, .respiratoryRate,
            .cgmTIR, .cgmMean, .sleepDeepPercent, .sleepREMPercent, .afBurden,
            .hba1c, .totalCholesterol, .ldlCholesterol, .hdlCholesterol,
            .triglycerides, .waistCircumference, .bodyMass,
        ]
        var baselines: [BaselineResult] = []
        var todayMetrics: [HealthMetric] = []
        var history: [ClinicalHistoryPoint] = []
        for type in types {
            let series = await healthProvider.dailySeries(type, days: 14)
            let result = BaselineEngine.evaluate(type: type, series: series)
            baselines.append(result)
            let snap = BaselineSnapshot(
                metricType: type,
                windowDays: result.windowDays,
                mean: result.mean,
                stdDev: result.stdDev
            )
            context.insert(snap)
            if let metric = await healthProvider.metric(type, on: Date()) {
                todayMetrics.append(metric)
            }
            if let key = type.clinicalKey {
                for point in series {
                    history.append(
                        ClinicalHistoryPoint(
                            metric: key,
                            value: point.value,
                            unit: type.unit,
                            timestamp: point.day,
                            deviceID: point.sourceName,
                            tags: [:]
                        )
                    )
                }
            }
        }
        let logs = (try? context.fetch(FetchDescriptor<DailyLogEntry>())) ?? []
        let todayLogs = logs.filter { Calendar.current.isDateInToday($0.createdAt) }
        let symptoms = todayLogs.flatMap(\.symptoms)
        let texts = todayLogs.map(\.displayBody)
        let highSugar = todayLogs.contains { entry in
            entry.tags.contains("饮食") && (entry.displayBody.contains("奶茶") || entry.displayBody.contains("糖") || entry.aiLabel?.contains("高糖") == true)
        }
        let drafts = AlertEngine.evaluate(
            profile: tags,
            baselines: baselines,
            todayMetrics: todayMetrics,
            recentSymptoms: symptoms,
            logText: texts,
            highSugarEvent: highSugar,
            rules: rules
        )
        let existingAlerts = (try? context.fetch(FetchDescriptor<AlertRecord>())) ?? []
        for old in existingAlerts where Calendar.current.isDateInToday(old.createdAt) {
            context.delete(old)
        }
        for draft in drafts {
            context.insert(
                AlertRecord(
                    tier: draft.tier,
                    title: draft.title,
                    whatChanged: draft.whatChanged,
                    baselineDelta: draft.baselineDelta,
                    whyItMatters: draft.whyItMatters,
                    suggestedAction: draft.suggestedAction,
                    evidence: draft.evidence,
                    relatedMetricTypes: draft.relatedMetricTypes,
                    ruleIDs: draft.ruleIDs
                )
            )
        }

        integrateClinicalEngine(todayMetrics: todayMetrics, history: history, profile: profile)

        let unwell = symptoms.contains { $0.severity != .mild } || baselines.contains { $0.persistent && $0.metricType == .sleepHours }
        lastAdvice = await AdviceEngine.run(
            input: AdvicePipelineInput(
                profile: tags,
                recipes: recipes,
                exercises: exercises,
                trendSummary: baselines.map {
                    "\($0.metricType.displayName) z=\($0.zScore.map { String(format: "%.1f", $0) } ?? "n/a")"
                }.joined(separator: "，"),
                feelingUnwell: unwell,
                todayStatus: TodayStatus.from(
                    alerts: (try? context.fetch(FetchDescriptor<AlertRecord>())) ?? []
                ).rawValue,
                dietRules: dietRules
            ),
            llm: currentLLM(),
            rules: rules
        )
        try? context.save()
    }

    private func integrateClinicalEngine(
        todayMetrics: [HealthMetric],
        history: [ClinicalHistoryPoint],
        profile: UserProfile
    ) {
        var measurements: [String: Double] = [:]
        for metric in todayMetrics {
            if let key = metric.type.clinicalKey {
                measurements[key] = metric.value
            }
        }
        guard !measurements.isEmpty else { return }

        let sex: String
        switch profile.biologicalSex {
        case .female: sex = "female"
        case .male: sex = "male"
        default: sex = "male"
        }
        let clinicalProfile = ClinicalUserProfile(
            age: ageYears(from: profile.birthDate),
            sex: sex,
            smoking: false
        )
        let response = ClinicalEngine.evaluateFull(
            measurements: measurements,
            profile: clinicalProfile,
            history: history.isEmpty ? nil : history
        )
        for (domain, result) in response.domains {
            guard result.riskLevel != .normal else { continue }
            for triggered in result.triggeredRules {
                let evidenceText = triggered.evidence.map { ev in
                    [ev.guideline, ev.section, ev.quote].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "；")
                }.joined(separator: " | ")
                context.insert(
                    AlertRecord(
                        tier: triggered.riskLevel.alertTier,
                        title: "指南评估: \(result.riskLevel.displayName)",
                        whatChanged: result.summary,
                        baselineDelta: triggered.data.map { "\($0.key)=\($0.value.displayText)" }.sorted().joined(separator: ", "),
                        whyItMatters: evidenceText.isEmpty ? result.summary : evidenceText,
                        suggestedAction: result.advice.first?.text ?? "建议咨询医生，本结果不构成诊断。",
                        evidence: evidenceText.isEmpty ? "规则 \(triggered.ruleID)" : evidenceText,
                        relatedMetricTypes: ClinicalEngine.metricTypes(forDomain: domain),
                        ruleIDs: [triggered.ruleID]
                    )
                )
            }
        }
    }

    private func ageYears(from date: Date?) -> Int {
        guard let date else { return 0 }
        return Calendar.current.dateComponents([.year], from: date, to: Date()).year ?? 0
    }

    private func persistSelection() {
        if let data = try? JSONEncoder().encode(activeSelection) {
            UserDefaults.standard.set(data, forKey: ActiveModelSelection.storageKey)
        }
    }
}

enum HealthKitRuntime {
    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }
}

enum DemoSeeder {
    static func seedIfNeeded(context: ModelContext) {
        let meds = (try? context.fetch(FetchDescriptor<Medication>())) ?? []
        if meds.isEmpty {
            context.insert(Medication(name: "氨氯地平", dosePerTime: "5mg", frequencyPerDay: 1, timesOfDay: ["08:00"], cautions: "按医嘱服用"))
            context.insert(Medication(name: "二甲双胍", dosePerTime: "500mg", frequencyPerDay: 2, timesOfDay: ["08:00", "18:00"], cautions: "随餐；漏服请咨询医生/药师"))
        }
        let follow = (try? context.fetch(FetchDescriptor<FollowUp>())) ?? []
        if follow.isEmpty, let date = Calendar.current.date(byAdding: .day, value: 12, to: Date()) {
            var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
            components.hour = 9
            components.minute = 30
            let appointment = Calendar.current.date(from: components) ?? date
            let item = FollowUp(
                mode: .doctorOrdered,
                date: appointment,
                department: "心内科",
                doctorName: "王医生",
                hospital: "市第一人民医院",
                preVisitRestrictions: ["空腹", "检查前勿剧烈运动"],
                materialsToBring: ["近期化验单", "用药清单", "近期手帐摘要"],
                notes: "医生口头医嘱，已手动记录",
                confirmedByUser: true
            )
            context.insert(item)
            let allFollowUps = (try? context.fetch(FetchDescriptor<FollowUp>())) ?? [item]
            NotificationService.syncFollowUpReminders(from: allFollowUps)
        }
        let logs = (try? context.fetch(FetchDescriptor<DailyLogEntry>())) ?? []
        if logs.isEmpty {
            let snap = WatermarkSnapshot(
                capturedAt: Date(),
                weekday: "星期四",
                sleepHours: 5.1,
                restingHeartRate: 76,
                currentHeartRate: 84,
                steps: 2800,
                bloodPressureSystolic: 138,
                bloodPressureDiastolic: 88,
                bloodGlucose: 7.4,
                sourceName: "Mock 剧本",
                weatherText: nil,
                locationText: nil
            )
            if let ref = try? PhotoStore.saveJPEG(WatermarkComposer.compose(DemoPhoto.make(), snapshot: snap, includeSensitive: false)) {
                context.insert(
                    DailyLogEntry(
                        kind: .photo,
                        photoRef: ref,
                        watermark: snap,
                        contentText: "晚饭后慢慢走了一圈",
                        tags: [LogTag.exercise.rawValue],
                        confirmation: .skipped
                    )
                )
            }
            context.insert(
                DailyLogEntry(
                    kind: .symptom,
                    contentText: "有一点乏力，已经休息",
                    tags: [LogTag.symptom.rawValue],
                    symptoms: [SymptomEntry(name: "乏力", severity: .mild)],
                    confirmation: .confirmed
                )
            )
        }
        try? context.save()
    }

    static func applyDemoPersona(_ profile: UserProfile) {
        if profile.conditions.isEmpty {
            profile.conditions = [ChronicCondition.hypertension.rawValue, ChronicCondition.diabetes.rawValue]
        }
        if profile.regionProvince.isEmpty {
            profile.regionProvince = "广东"
            profile.spiciness = .none
        }
        if profile.dietGoals.isEmpty {
            profile.dietGoals = [DietGoal.saltControl.rawValue, DietGoal.sugarControl.rawValue]
        }
        profile.applyConditionConstraints()
    }
}
