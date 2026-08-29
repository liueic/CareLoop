import Foundation
import SwiftData
import Testing

@testable import CareLoop

/// 可配置 listModels 结果/抛错的打桩。
final class ScriptedListModelsProvider: LLMProviding, @unchecked Sendable {
    var supportsVision: Bool { false }
    var ids: [String]
    var thrownError: Error?

    init(ids: [String] = [], thrownError: Error? = nil) {
        self.ids = ids
        self.thrownError = thrownError
    }

    func complete(prompt: LLMPrompt) async throws -> LLMCompletion {
        LLMCompletion(text: "", modelID: "stub")
    }

    func completeConversation(_ request: LLMConversationRequest) async throws -> LLMConversationResponse {
        LLMConversationResponse(
            message: LLMChatMessage(role: "assistant", content: "", toolCallID: nil, toolCalls: []),
            modelID: "stub",
            finishReason: "stop"
        )
    }

    func listModels() async throws -> [String] {
        if let thrownError { throw thrownError }
        return ids
    }

    func ping(modelID: String) async throws -> TimeInterval { 0.05 }
}

/// /models 发现同步：新增、刷新、清理 stale（只动 .discovered）、失败透传、toolCall 默认开启。
@MainActor
struct ModelDiscoveryTests {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ModelCatalogEntry.self,
            configurations: config
        )
        return ModelContext(container)
    }

    @Test func insertsNewModelsWithToolCallEnabled() async throws {
        let context = try makeContext()
        let outcome = await ModelDiscovery.discover(
            using: ScriptedListModelsProvider(ids: ["model-a", "model-b"]),
            providerKey: "custom",
            context: context
        )
        #expect(outcome.errorMessage == nil)
        #expect(outcome.added == 2)
        let entries = try context.fetch(FetchDescriptor<ModelCatalogEntry>())
        #expect(entries.count == 2)
        // OpenAI 兼容端点主流支持 tools：发现的模型默认开启工具调用（宝宝助手依赖）
        #expect(entries.allSatisfy { $0.supportsToolCall })
        #expect(entries.allSatisfy { $0.metadataUnknown })
        #expect(outcome.removedStale == 0)
    }

    @Test func refreshesExistingAndRemovesStaleDiscoveredOnly() async throws {
        let context = try makeContext()
        // 预置：一个会被刷新的 discovered、一个已下线的 discovered、一个 bundled、一个 manual
        context.insert(ModelCatalogEntry(
            modelID: "keep-me", providerKey: "custom", displayName: "旧名字",
            contextWindow: 0, maxOutputTokens: 0, supportsVision: false,
            supportsToolCall: false, supportsReasoning: false, inputPrice: 0, outputPrice: 0,
            knowledgeCutoff: "", source: .discovered, metadataUnknown: true
        ))
        context.insert(ModelCatalogEntry(
            modelID: "gone-model", providerKey: "custom", displayName: "gone",
            contextWindow: 0, maxOutputTokens: 0, supportsVision: false,
            supportsToolCall: false, supportsReasoning: false, inputPrice: 0, outputPrice: 0,
            knowledgeCutoff: "", source: .discovered, metadataUnknown: true
        ))
        context.insert(ModelCatalogEntry(
            modelID: "bundled-model", providerKey: "custom", displayName: "bundled",
            contextWindow: 0, maxOutputTokens: 0, supportsVision: false,
            supportsToolCall: false, supportsReasoning: false, inputPrice: 0, outputPrice: 0,
            knowledgeCutoff: "", source: .bundled
        ))
        context.insert(ModelCatalogEntry(
            modelID: "my-manual", providerKey: "custom", displayName: "my-manual",
            contextWindow: 0, maxOutputTokens: 0, supportsVision: false,
            supportsToolCall: true, supportsReasoning: false, inputPrice: 0, outputPrice: 0,
            knowledgeCutoff: "", source: .manual, metadataUnknown: true
        ))
        try context.save()

        let outcome = await ModelDiscovery.discover(
            using: ScriptedListModelsProvider(ids: ["keep-me", "new-model"]),
            providerKey: "custom",
            context: context
        )
        #expect(outcome.added == 1)
        #expect(outcome.updated == 1)
        #expect(outcome.removedStale == 1)

        let entries = try context.fetch(FetchDescriptor<ModelCatalogEntry>())
        let ids = Set(entries.map(\.modelID))
        // 已下线的 discovered 被清理；bundled/manual 即使不再返回也保留
        #expect(ids == ["keep-me", "new-model", "bundled-model", "my-manual"])
        #expect(entries.first { $0.modelID == "keep-me" }?.displayName == "keep-me")
    }

    @Test func errorIsSurfacedNotSwallowed() async {
        let context: ModelContext
        do {
            context = try makeContext()
        } catch {
            Issue.record("容器创建失败: \(error)")
            return
        }
        let outcome = await ModelDiscovery.discover(
            using: ScriptedListModelsProvider(thrownError: LLMError.network("HTTP 404")),
            providerKey: "custom",
            context: context
        )
        #expect(outcome.errorMessage == "HTTP 404")
        #expect(outcome.added == 0)
    }

    @Test func otherProvidersEntriesUntouched() async throws {
        let context = try makeContext()
        context.insert(ModelCatalogEntry(
            modelID: "deepseek-chat", providerKey: "deepseek", displayName: "DeepSeek Chat",
            contextWindow: 0, maxOutputTokens: 0, supportsVision: false,
            supportsToolCall: false, supportsReasoning: false, inputPrice: 0, outputPrice: 0,
            knowledgeCutoff: "", source: .discovered, metadataUnknown: true
        ))
        try context.save()
        _ = await ModelDiscovery.discover(
            using: ScriptedListModelsProvider(ids: ["other-model"]),
            providerKey: "custom",
            context: context
        )
        let ids = try context.fetch(FetchDescriptor<ModelCatalogEntry>()).map(\.modelID)
        #expect(Set(ids) == ["deepseek-chat", "other-model"])
    }
}
