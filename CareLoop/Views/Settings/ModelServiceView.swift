import SwiftData
import SwiftUI

struct ModelServiceView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(sort: \LLMProviderConfig.name) private var providers: [LLMProviderConfig]
    @Query(sort: \ModelCatalogEntry.displayName) private var models: [ModelCatalogEntry]
    @State private var keyDrafts: [UUID: String] = [:]
    @State private var customName = ""
    @State private var customURL = "http://127.0.0.1:11434/v1"
    @State private var customKey = ""
    @State private var manualProviderKey = ""
    @State private var manualModelID = ""
    @State private var busyProviderKeys: Set<String> = []
    @State private var providerNotes: [UUID: String] = [:]
    @State private var pingBusyIDs: Set<UUID> = []
    @State private var pingFailures: [UUID: String] = [:]
    @State private var message = ""

    private var currentProviderModels: [ModelCatalogEntry] {
        models.filter { $0.providerKey == env.activeSelection.providerKey }
    }

    var body: some View {
        List {
            Section("当前激活") {
                Picker("Provider", selection: Binding(
                    get: { env.activeSelection.providerKey },
                    set: { newKey in
                        // 切换 Provider 时清空旧模型 ID，避免把 A 家的模型名发到 B 家（运行时 404）
                        env.activeSelection = ActiveModelSelection(providerKey: newKey, modelID: "")
                        sanitizeSelectionForCurrentProvider()
                    }
                )) {
                    ForEach(providers, id: \.key) { Text($0.name).tag($0.key) }
                }
                Picker("模型", selection: Bindable(env).activeSelection.modelID) {
                    ForEach(currentProviderModels, id: \.modelID) { model in
                        Text(model.displayName + (model.supportsVision ? " · vision" : "")).tag(model.modelID)
                    }
                }
                if currentProviderModels.isEmpty {
                    Text("该 Provider 暂无模型：点下方「拉取模型」调用 /models，或用「手动添加模型」填写。")
                        .font(.caption)
                        .foregroundStyle(CareTheme.warn)
                }
                Text("食物识别需要 supportsVision = true 的模型。")
                    .font(.caption)
                    .foregroundStyle(CareTheme.muted)
            }
            Section("Provider") {
                ForEach(providers, id: \.id) { provider in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(provider.name).font(.headline)
                            Spacer()
                            statusDot(provider.healthStatus)
                        }
                        Text(provider.baseURL).font(.caption).foregroundStyle(CareTheme.muted)
                        SecureField("API Key", text: Binding(
                            get: { keyDrafts[provider.id] ?? "" },
                            set: { keyDrafts[provider.id] = $0 }
                        ))
                        HStack {
                            Button("保存 Key") {
                                let secret = keyDrafts[provider.id] ?? ""
                                ProviderManager(context: env.context).saveKey(secret, for: provider)
                                providerNotes[provider.id] = "Key 已保存"
                            }
                            Button("测活") {
                                Task { await check(provider) }
                            }
                            .disabled(busyProviderKeys.contains(provider.key))
                            Button(busyProviderKeys.contains(provider.key) ? "拉取中…" : "拉取模型") {
                                Task { await fetchModels(provider) }
                            }
                            .disabled(busyProviderKeys.contains(provider.key))
                            Toggle("启用", isOn: Bindable(provider).enabled)
                        }
                        .font(.caption)
                        if let note = providerNotes[provider.id] {
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(CareTheme.muted)
                        }
                    }
                }
            }
            Section("自定义 Provider") {
                TextField("名称", text: $customName)
                TextField("Base URL", text: $customURL)
                SecureField("API Key（可空）", text: $customKey)
                Button("添加") {
                    ProviderManager(context: env.context).upsertCustom(name: customName, baseURL: customURL, key: customKey)
                    customName = ""
                    message = "已保存。同名 Provider 会更新地址与 Key。"
                }
                .disabled(customName.isEmpty || customURL.isEmpty)
            }
            Section("手动添加模型") {
                Picker("Provider", selection: $manualProviderKey) {
                    ForEach(providers, id: \.key) { Text($0.name).tag($0.key) }
                }
                TextField("模型 ID（如 deepseek-chat）", text: $manualModelID)
                Button("添加") {
                    let added = ProviderManager(context: env.context).addManualModel(
                        providerKey: manualProviderKey,
                        modelID: manualModelID
                    )
                    if added != nil {
                        message = "已添加模型 \(manualModelID.trimmingCharacters(in: .whitespaces))"
                        manualModelID = ""
                        if manualProviderKey == env.activeSelection.providerKey {
                            sanitizeSelectionForCurrentProvider()
                        }
                    } else {
                        message = "添加失败：模型 ID 为空或已存在"
                    }
                }
                .disabled(manualModelID.trimmingCharacters(in: .whitespaces).isEmpty || manualProviderKey.isEmpty)
                Text("适用于不提供 /models 列表接口的端点（部分代理/网关）。")
                    .font(.caption)
                    .foregroundStyle(CareTheme.muted)
            }
            Section("模型目录") {
                Button("同步 models.dev 元数据") {
                    Task {
                        busyProviderKeys.insert("__catalog__")
                        await CatalogSyncService.syncIfNeeded(context: env.context, force: true)
                        busyProviderKeys.remove("__catalog__")
                        message = "已尝试同步。失败时沿用内置快照。"
                    }
                }
                .disabled(busyProviderKeys.contains("__catalog__"))
                ForEach(models, id: \.id) { model in
                    modelRow(model)
                }
            }
            if !message.isEmpty {
                Section { Text(message).font(.caption) }
            }
        }
        .navigationTitle("模型服务")
        .onAppear {
            for provider in providers {
                keyDrafts[provider.id] = ProviderManager(context: env.context).key(for: provider)
            }
            if manualProviderKey.isEmpty {
                manualProviderKey = env.activeSelection.providerKey
            }
            sanitizeSelectionForCurrentProvider()
        }
    }

    // MARK: - 模型目录行

    private func modelRow(_ model: ModelCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.displayName)
                Spacer()
                statusDot(model.lastPingStatus)
                if model.source == .discovered || model.source == .manual {
                    Button {
                        ProviderManager(context: env.context).deleteModel(model)
                        if model.providerKey == env.activeSelection.providerKey {
                            sanitizeSelectionForCurrentProvider()
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .font(.caption)
                }
            }
            Text("\(model.providerKey) · ctx \(model.contextWindow) · \(model.supportsVision ? "vision" : "text")\(model.supportsReasoning ? " · 思考型" : "") · \(model.source.rawValue)")
                .font(.caption)
                .foregroundStyle(CareTheme.muted)
            if model.metadataUnknown {
                // 元数据未核实的条目（/models 发现或手动添加）允许手动标注视觉能力，解锁食物识别
                Toggle("视觉（食物识别需要）", isOn: Bindable(model).supportsVision)
                    .font(.caption)
            }
            HStack {
                Button(pingBusyIDs.contains(model.id) ? "测活中…" : "模型测活") {
                    Task { await ping(model) }
                }
                .font(.caption)
                .disabled(pingBusyIDs.contains(model.id))
                if let ms = model.lastPingMS {
                    Text(String(format: "%.0f ms", ms))
                        .font(.caption2)
                        .foregroundStyle(CareTheme.muted)
                }
                if let failure = pingFailures[model.id] {
                    Text("失败：\(failure)")
                        .font(.caption2)
                        .foregroundStyle(CareTheme.warn)
                }
            }
        }
    }

    // MARK: - 动作

    /// 当前 Provider 的模型选择不在目录中时重置为第一个，避免陈旧 ID。
    private func sanitizeSelectionForCurrentProvider() {
        let list = currentProviderModels
        guard !list.isEmpty else { return }
        if !list.contains(where: { $0.modelID == env.activeSelection.modelID }) {
            env.activeSelection.modelID = list.first?.modelID ?? ""
        }
    }

    private func check(_ provider: LLMProviderConfig) async {
        guard !busyProviderKeys.contains(provider.key) else { return }
        busyProviderKeys.insert(provider.key)
        defer { busyProviderKeys.remove(provider.key) }
        let key = ProviderManager(context: env.context).key(for: provider)
        let outcome = await HealthCheckService.connectivity(provider: provider, apiKey: key)
        provider.healthStatus = outcome.status
        provider.lastHealthAt = Date()
        provider.lastLatencyMS = outcome.latency.map { $0 * 1000 }
        try? env.context.save()
        providerNotes[provider.id] = outcome.message.map { "失败：\($0)" }
            ?? outcome.latency.map { String(format: "连通 · %.0f ms", $0 * 1000) }
            ?? "连通"
    }

    /// 调用 GET {base}/models 拉取该 Provider 的可用模型列表。
    private func fetchModels(_ provider: LLMProviderConfig) async {
        guard !busyProviderKeys.contains(provider.key) else { return }
        guard let url = URL(string: provider.baseURL) else {
            providerNotes[provider.id] = "失败：Base URL 无法解析"
            return
        }
        busyProviderKeys.insert(provider.key)
        defer { busyProviderKeys.remove(provider.key) }
        let key = ProviderManager(context: env.context).key(for: provider)
        let llm = OpenAIProvider(
            name: provider.name,
            baseURL: url,
            apiKey: key,
            modelID: env.activeSelection.modelID,
            supportsVision: false
        )
        let outcome = await ModelDiscovery.discover(using: llm, providerKey: provider.key, context: env.context)
        if let error = outcome.errorMessage {
            providerNotes[provider.id] = "拉取失败：\(error)（端点可能不提供 /models，可手动添加模型）"
        } else {
            providerNotes[provider.id] = "新增 \(outcome.added) · 更新 \(outcome.updated) · 清理 \(outcome.removedStale)"
            if provider.key == env.activeSelection.providerKey {
                sanitizeSelectionForCurrentProvider()
            }
        }
    }

    private func ping(_ model: ModelCatalogEntry) async {
        guard let provider = providers.first(where: { $0.key == model.providerKey }) else { return }
        guard !pingBusyIDs.contains(model.id) else { return }
        pingBusyIDs.insert(model.id)
        defer { pingBusyIDs.remove(model.id) }
        let key = ProviderManager(context: env.context).key(for: provider)
        let outcome = await HealthCheckService.pingModel(provider: provider, apiKey: key, modelID: model.modelID)
        model.lastPingStatus = outcome.status
        model.lastPingAt = Date()
        model.lastPingMS = outcome.latency.map { $0 * 1000 }
        pingFailures[model.id] = outcome.message
        try? env.context.save()
    }

    // MARK: - 状态展示

    private func statusDot(_ status: ProviderHealthStatus) -> some View {
        Circle()
            .fill(color(status))
            .frame(width: 10, height: 10)
    }

    private func color(_ status: ProviderHealthStatus) -> Color {
        switch status {
        case .ok: .green
        case .degraded: .yellow
        case .down: .red
        case .unknown: .gray
        }
    }
}
