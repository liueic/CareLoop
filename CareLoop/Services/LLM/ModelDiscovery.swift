import Foundation
import SwiftData

/// GET {base}/models 的模型发现与目录同步（每次全量对账）。
@MainActor
enum ModelDiscovery {
    struct Outcome {
        var added: Int = 0
        var updated: Int = 0
        var removedStale: Int = 0
        var errorMessage: String?
    }

    /// 拉取 provider 的可用模型并同步目录：
    /// - 新 ID 插入（supportsToolCall 默认 true——OpenAI 兼容端点主流支持 tools，
    ///   metadataUnknown 保持 true 标注能力未核实）；
    /// - 已有 `.discovered` 条目刷新 displayName；
    /// - 端点已下线、不再返回的 `.discovered` 条目删除（bundled/synced/manual 不动）；
    /// - 失败原因透传给 UI，不再静默。
    @discardableResult
    static func discover(
        using llm: any LLMProviding,
        providerKey: String,
        context: ModelContext
    ) async -> Outcome {
        var outcome = Outcome()
        let ids: [String]
        do {
            ids = try await llm.listModels()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            outcome.errorMessage = message
            return outcome
        }
        let existing = (try? context.fetch(FetchDescriptor<ModelCatalogEntry>())) ?? []
        let mine = existing.filter { $0.providerKey == providerKey }
        for id in ids {
            if let found = mine.first(where: { $0.modelID == id }) {
                if found.displayName != id {
                    found.displayName = id
                    outcome.updated += 1
                }
                continue
            }
            context.insert(
                ModelCatalogEntry(
                    modelID: id,
                    providerKey: providerKey,
                    displayName: id,
                    contextWindow: 0,
                    maxOutputTokens: 0,
                    supportsVision: false,
                    supportsToolCall: true,
                    supportsReasoning: false,
                    inputPrice: 0,
                    outputPrice: 0,
                    knowledgeCutoff: "",
                    source: .discovered,
                    metadataUnknown: true
                )
            )
            outcome.added += 1
        }
        let returned = Set(ids)
        for entry in mine where entry.source == .discovered && !returned.contains(entry.modelID) {
            context.delete(entry)
            outcome.removedStale += 1
        }
        try? context.save()
        return outcome
    }
}
