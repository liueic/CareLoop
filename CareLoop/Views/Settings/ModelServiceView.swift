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
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        List {
            Section("当前激活") {
                Picker("Provider", selection: Bindable(env).activeSelection.providerKey) {
                    ForEach(providers, id: \.key) { Text($0.name).tag($0.key) }
                }
                Picker("模型", selection: Bindable(env).activeSelection.modelID) {
                    ForEach(models.filter { $0.providerKey == env.activeSelection.providerKey }, id: \.modelID) { model in
                        Text(model.displayName + (model.supportsVision ? " · vision" : "")).tag(model.modelID)
                    }
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
                            }
                            Button("测活") {
                                Task { await check(provider) }
                            }
                            Toggle("启用", isOn: Bindable(provider).enabled)
                        }
                        .font(.caption)
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
                }
                .disabled(customName.isEmpty || customURL.isEmpty)
            }
            Section("模型目录") {
                Button(busy ? "同步中…" : "手动同步 models.dev") {
                    Task {
                        busy = true
                        await CatalogSyncService.syncIfNeeded(context: env.context, force: true)
                        busy = false
                        message = "已尝试同步。失败时沿用内置快照。"
                    }
                }
                ForEach(models, id: \.id) { model in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.displayName)
                        Text("\(model.providerKey) · ctx \(model.contextWindow) · \(model.supportsVision ? "vision" : "text") · \(model.source.rawValue)")
                            .font(.caption)
                            .foregroundStyle(CareTheme.muted)
                        if model.metadataUnknown {
                            Text("元数据未知，可手动补全")
                                .font(.caption2)
                        }
                        HStack {
                            statusDot(model.lastPingStatus)
                            Button("模型测活") {
                                Task { await ping(model) }
                            }
                            .font(.caption)
                        }
                    }
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
        }
    }

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

    private func check(_ provider: LLMProviderConfig) async {
        let key = ProviderManager(context: env.context).key(for: provider)
        let result = await HealthCheckService.connectivity(provider: provider, apiKey: key)
        provider.healthStatus = result.0
        provider.lastHealthAt = Date()
        provider.lastLatencyMS = result.1.map { $0 * 1000 }
        try? env.context.save()
        if let url = URL(string: provider.baseURL) {
            let llm = OpenAICompatibleProvider(
                name: provider.name,
                baseURL: url,
                apiKey: key,
                modelID: env.activeSelection.modelID,
                supportsVision: false
            )
            await ModelDiscovery.discover(using: llm, providerKey: provider.key, context: env.context)
        }
    }

    private func ping(_ model: ModelCatalogEntry) async {
        guard let provider = providers.first(where: { $0.key == model.providerKey }) else { return }
        let key = ProviderManager(context: env.context).key(for: provider)
        let result = await HealthCheckService.pingModel(provider: provider, apiKey: key, modelID: model.modelID)
        model.lastPingStatus = result.0
        model.lastPingAt = Date()
        model.lastPingMS = result.1.map { $0 * 1000 }
        try? env.context.save()
    }
}
