import SwiftUI

struct OnboardingFlowView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var step = 0
    @State private var prefill: CharacteristicSnapshot?

    var body: some View {
        @Bindable var draft = env.profile()
        NavigationStack {
            Group {
                if step == 0 {
                    WelcomeView(skip: { advance(draft, skipping: true) }) {
                        advance(draft, skipping: false)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        ProgressView(value: Double(step), total: 5)
                            .tint(CareTheme.sage)
                        Group {
                            switch step {
                            case 1: basics(draft)
                            case 2: conditions(draft)
                            case 3: diet(draft)
                            case 4: movement(draft)
                            default: ConnectView {
                                advance(draft, skipping: false)
                            } skip: {
                                advance(draft, skipping: true)
                            }
                            }
                        }
                        if step < 5 {
                            Spacer()
                            HStack {
                                Button("稍后再说") { advance(draft, skipping: true) }
                                    .foregroundStyle(CareTheme.muted)
                                    .accessibilityIdentifier("onboarding.skip")
                                Spacer()
                                Button("继续") { advance(draft, skipping: false) }
                                    .buttonStyle(.borderedProminent)
                                    .tint(CareTheme.sage)
                                    .accessibilityIdentifier("onboarding.continue")
                            }
                        } else {
                            Spacer(minLength: 0)
                        }
                    }
                    .padding()
                }
            }
            .background(CareTheme.paper.ignoresSafeArea())
        }
    }

    private func basics(_ draft: UserProfile) -> some View {
        @Bindable var draft = draft
        return Form {
            DatePicker("出生日期", selection: Binding(get: {
                draft.birthDate ?? Calendar.current.date(byAdding: .year, value: -50, to: Date())!
            }, set: { draft.birthDate = $0 }), displayedComponents: .date)
            Picker("生理性别", selection: $draft.biologicalSexRaw) {
                ForEach(BiologicalSex.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            Picker("血型", selection: $draft.bloodTypeRaw) {
                ForEach(BloodType.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            TextField("身高 cm", value: $draft.heightCM, format: .number)
            TextField("体重 kg", value: $draft.weightKG, format: .number)
            if prefill != nil {
                Text("以上来自 Apple Health 预填，确认后才会保存。")
                    .font(.caption)
                    .foregroundStyle(CareTheme.muted)
            }
        }
        .scrollContentBackground(.hidden)
        .task { await loadPrefill(draft) }
    }

    private func conditions(_ draft: UserProfile) -> some View {
        @Bindable var draft = draft
        return Form {
            Section("确诊慢病（可多选）") {
                ForEach(ChronicCondition.allCases) { condition in
                    Toggle(condition.rawValue, isOn: listBinding(condition.rawValue, draft: draft, keyPath: \.conditions))
                }
            }
            Section("过敏 / 限制") {
                chipField("药物过敏", textToList: $draft.drugAllergies)
                chipField("食物过敏", textToList: $draft.foodAllergies)
                chipField("当前用药", textToList: $draft.currentMedicationNames)
                chipField("运动损伤", textToList: $draft.injuries)
                chipField("医生限制", textToList: $draft.doctorRestrictions)
            }
        }
        .scrollContentBackground(.hidden)
        .onChange(of: draft.conditions) { _, _ in
            draft.applyConditionConstraints()
        }
    }

    private func diet(_ draft: UserProfile) -> some View {
        @Bindable var draft = draft
        return Form {
            TextField("省份", text: $draft.regionProvince)
            TextField("城市", text: $draft.regionCity)
            Picker("辣度", selection: $draft.spicinessRaw) {
                ForEach(Spiciness.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            chipField("喜欢的菜系", textToList: $draft.cuisineLikes)
            chipField("不接受的菜系", textToList: $draft.cuisineDislikes)
            chipField("忌口食材", textToList: $draft.dislikedIngredients)
            Picker("做饭频率", selection: $draft.cookFrequencyRaw) {
                ForEach(CookFrequency.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            ForEach(DietGoal.allCases, id: \.rawValue) { goal in
                Toggle(goal.rawValue, isOn: listBinding(goal.rawValue, draft: draft, keyPath: \.dietGoals))
            }
        }
        .scrollContentBackground(.hidden)
        .onChange(of: draft.regionProvince) { _, new in
            if new.contains("广东") { draft.spiciness = .none }
        }
    }

    private func movement(_ draft: UserProfile) -> some View {
        @Bindable var draft = draft
        return Form {
            chipField("喜欢的运动", textToList: $draft.preferredSports)
            chipField("不想/不能做的运动", textToList: $draft.avoidedSports)
            Picker("频率", selection: $draft.exerciseFrequencyRaw) {
                ForEach(ExerciseFrequency.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            Picker("时段", selection: $draft.timePreferenceRaw) {
                ForEach(TimePreference.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            chipField("场地/器械", textToList: $draft.facilities)
            Text("强度上限：\(draft.intensityCeiling.rawValue)")
                .foregroundStyle(CareTheme.muted)
            Text("心脏病/房颤会自动把 HIIT、短跑、球类对抗标为不推荐。")
                .font(.caption)
        }
        .scrollContentBackground(.hidden)
    }

    private func listBinding(
        _ value: String,
        draft: UserProfile,
        keyPath: ReferenceWritableKeyPath<UserProfile, [String]>
    ) -> Binding<Bool> {
        Binding(
            get: { draft[keyPath: keyPath].contains(value) },
            set: { on in
                if on {
                    if !draft[keyPath: keyPath].contains(value) { draft[keyPath: keyPath].append(value) }
                } else {
                    draft[keyPath: keyPath].removeAll { $0 == value }
                }
            }
        )
    }

    private func chipField(_ title: String, textToList: Binding<[String]>) -> some View {
        TextField(title + "（逗号分隔）", text: Binding(
            get: { textToList.wrappedValue.joined(separator: "，") },
            set: { textToList.wrappedValue = $0.split { "，,、".contains($0) }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        ))
    }

    private func loadPrefill(_ draft: UserProfile) async {
        let snap = await env.healthProvider.characteristics()
        prefill = snap
        if draft.birthDate == nil { draft.birthDate = snap.birthDate }
        if let sex = snap.biologicalSex { draft.biologicalSex = sex }
        if let blood = snap.bloodType { draft.bloodType = blood }
        if draft.heightCM == nil { draft.heightCM = snap.heightCM }
        if draft.weightKG == nil { draft.weightKG = snap.weightKG }
        if let chair = snap.wheelchairUse { draft.wheelchairUse = chair }
    }

    private func advance(_ draft: UserProfile, skipping: Bool) {
        if step < 5 {
            if step == 2 { draft.applyConditionConstraints() }
            step += 1
            return
        }
        draft.applyConditionConstraints()
        draft.onboardingCompleted = true
        if skipping {
            draft.intensityCeiling = .low
            if env.demoMode {
                DemoSeeder.applyDemoPersona(draft)
            }
        }
        try? env.context.save()
        Task { await env.refreshTodayPipeline() }
    }
}
