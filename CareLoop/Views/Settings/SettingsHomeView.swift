import SwiftData
import SwiftUI

struct SettingsHomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    @Query private var profiles: [UserProfile]
    @State private var hour = 19
    @State private var minute = 30
    @State private var amapKeyDraft = ""
    @State private var amapKeyNote = ""

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
                Section("地图服务") {
                    amapKeySection
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

    // MARK: 高德 MCP Key 配置

    @ViewBuilder
    private var amapKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("高德 Key（Web 服务，可留空用内置）", text: $amapKeyDraft)
                .font(.caption)
            HStack {
                Button("保存 Key") {
                    let trimmed = amapKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        KeychainStore.delete(key: AmapServiceConfig.keychainKey, service: AmapServiceConfig.keychainService)
                    } else {
                        KeychainStore.save(
                            key: AmapServiceConfig.keychainKey,
                            secret: trimmed,
                            service: AmapServiceConfig.keychainService
                        )
                    }
                    env.refreshNearbyService()
                    amapKeyNote = trimmed.isEmpty ? "已清除自定义 Key" : "Key 已保存"
                }
                .font(.caption.weight(.semibold))
                Spacer()
                Button("申请高德 Key") {
                    openURL(URL(string: "https://console.amap.com/dev/key/app")!)
                }
                .font(.caption)
            }
            Text(amapKeyNote)
                .font(.caption2)
                .foregroundStyle(CareTheme.muted)
            Text("用于「饱饱」的附近餐厅搜索（高德 MCP 服务）。仅发送当前位置与搜索关键词，不发送任何健康数据；Key 保存在本机 Keychain。")
                .font(.caption2)
                .foregroundStyle(CareTheme.muted)
        }
        .onAppear {
            let stored = KeychainStore.load(key: AmapServiceConfig.keychainKey, service: AmapServiceConfig.keychainService)
            amapKeyDraft = stored
            amapKeyNote = stored.isEmpty
                ? (AmapServiceConfig.bundledKey.isEmpty ? "未配置：附近搜索不可用" : "使用内置默认 Key")
                : "使用自定义 Key"
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
