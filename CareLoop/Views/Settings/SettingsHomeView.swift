import SwiftData
import SwiftUI

struct SettingsHomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Query private var profiles: [UserProfile]
    @State private var hour = 19
    @State private var minute = 30

    var body: some View {
        NavigationStack {
            List {
                if let profile = profiles.first {
                    Section("画像") {
                        Text("完成度 \(Int(profile.completionScore * 100))%")
                        NavigationLink("完善资料") { ProfileEditView(profile: profile) }
                    }
                    Section("水印显示") {
                        Toggle("水印显示血压", isOn: Bindable(profile).showBPOnWatermark)
                        Toggle("水印显示血糖", isOn: Bindable(profile).showGlucoseOnWatermark)
                        Text("默认关闭，避免照片含敏感指标。")
                            .font(.caption)
                            .foregroundStyle(CareTheme.muted)
                    }
                    Section("轻提醒") {
                        Stepper("小时 \(profile.reminderHour)", value: Bindable(profile).reminderHour, in: 6...22)
                        Stepper("分钟 \(profile.reminderMinute)", value: Bindable(profile).reminderMinute, in: 0...59)
                        Button("保存提醒时间") {
                            NotificationService.scheduleDailyJournalReminder(hour: profile.reminderHour, minute: profile.reminderMinute)
                            try? env.context.save()
                        }
                    }
                }
                Section("数据与演示") {
                    Toggle("演示模式（Mock 剧本数据）", isOn: Bindable(env).demoMode)
                    Text(env.demoMode ? "当前使用 30 天剧本数据：近 3 天睡眠下降 + 静息心率上升。" : "真机将尝试读取 Apple Health。拿不到的指标会降级。")
                        .font(.caption)
                        .foregroundStyle(CareTheme.muted)
                    Text("数据来源会如实展示为 Apple Watch / 第三方 / Mock。")
                        .font(.caption)
                }
                Section("模型服务") {
                    NavigationLink("Provider 与模型目录") { ModelServiceView() }
                }
                Section("关于") {
                    DisclaimerBanner()
                    Text("MVP v0.1 · 慢病日常管理工具")
                        .font(.caption)
                }
            }
            .navigationTitle("我的")
        }
    }
}

struct ProfileEditView: View {
    @Bindable var profile: UserProfile
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Form {
            DatePicker(
                "出生日期",
                selection: Binding(
                    get: { profile.birthDate ?? Date() },
                    set: { profile.birthDate = $0 }
                ),
                displayedComponents: .date
            )
            Picker("性别", selection: $profile.biologicalSexRaw) {
                ForEach(BiologicalSex.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            TextField("省份", text: $profile.regionProvince)
            chip("慢病", $profile.conditions)
            chip("忌口", $profile.dislikedIngredients)
            Picker("辣度", selection: $profile.spicinessRaw) {
                ForEach(Spiciness.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            Button("按病种更新约束") {
                profile.applyConditionConstraints()
                try? env.context.save()
            }
        }
        .navigationTitle("资料")
        .onDisappear { try? env.context.save() }
    }

    private func chip(_ title: String, _ list: Binding<[String]>) -> some View {
        TextField(title, text: Binding(
            get: { list.wrappedValue.joined(separator: "，") },
            set: { list.wrappedValue = $0.split { "，,、".contains($0) }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        ))
    }
}
