import Foundation
import SwiftData
import Testing

@testable import CareLoop

/// Provider 配置管理：自定义 Provider 真 upsert、手动模型登记与删除。
@MainActor
struct ProviderManagerTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: LLMProviderConfig.self, ModelCatalogEntry.self,
            configurations: config
        )
        return ModelContext(container)
    }

    @Test func upsertCustomUpdatesInsteadOfDuplicating() throws {
        let context = try makeContext()
        let manager = ProviderManager(context: context)

        manager.upsertCustom(name: "My Gateway", baseURL: "http://127.0.0.1:8000/v1", key: "")
        manager.upsertCustom(name: "My Gateway", baseURL: "http://127.0.0.1:9000/v1", key: "")
        // 名称规范化后 slug 相同 → 更新而非重复插入（避免 Keychain ref 冲突）
        manager.upsertCustom(name: " my gateway ", baseURL: "http://10.0.0.2:8000/v1", key: "")

        let providers = manager.providers()
        #expect(providers.count == 1)
        #expect(providers[0].key == "my-gateway")
        #expect(providers[0].baseURL == "http://10.0.0.2:8000/v1")
        #expect(!providers[0].isPreset)
    }

    @Test func addManualModelDedupesAndDefaults() throws {
        let context = try makeContext()
        let manager = ProviderManager(context: context)
        manager.upsertCustom(name: "NoList Gateway", baseURL: "http://127.0.0.1:8000/v1", key: "")

        let added = manager.addManualModel(providerKey: "nolist-gateway", modelID: "my-model")
        #expect(added != nil)
        // 重复添加同一 ID → nil，不重复插入
        #expect(manager.addManualModel(providerKey: "nolist-gateway", modelID: "my-model") == nil)
        // 空白 ID → nil
        #expect(manager.addManualModel(providerKey: "nolist-gateway", modelID: "  ") == nil)

        let models = manager.models(providerKey: "nolist-gateway")
        #expect(models.count == 1)
        #expect(models[0].source == .manual)
        #expect(models[0].supportsToolCall)
        #expect(models[0].metadataUnknown)
    }

    @Test func deleteModelOnlyForManualAndDiscovered() throws {
        let context = try makeContext()
        let manager = ProviderManager(context: context)
        manager.upsertCustom(name: "GW", baseURL: "http://127.0.0.1:8000/v1", key: "")
        _ = manager.addManualModel(providerKey: "gw", modelID: "manual-model")
        context.insert(ModelCatalogEntry(
            modelID: "found-model", providerKey: "gw", displayName: "found-model",
            contextWindow: 0, maxOutputTokens: 0, supportsVision: false,
            supportsToolCall: true, supportsReasoning: false, inputPrice: 0, outputPrice: 0,
            knowledgeCutoff: "", source: .discovered, metadataUnknown: true
        ))
        context.insert(ModelCatalogEntry(
            modelID: "synced-model", providerKey: "gw", displayName: "synced-model",
            contextWindow: 0, maxOutputTokens: 0, supportsVision: false,
            supportsToolCall: false, supportsReasoning: false, inputPrice: 0, outputPrice: 0,
            knowledgeCutoff: "", source: .synced
        ))
        try context.save()

        let synced = manager.models(providerKey: "gw").first { $0.modelID == "synced-model" }!
        manager.deleteModel(synced)
        #expect(manager.models(providerKey: "gw").contains { $0.modelID == "synced-model" })

        let manual = manager.models(providerKey: "gw").first { $0.modelID == "manual-model" }!
        manager.deleteModel(manual)
        #expect(!manager.models(providerKey: "gw").contains { $0.modelID == "manual-model" })
    }
}
