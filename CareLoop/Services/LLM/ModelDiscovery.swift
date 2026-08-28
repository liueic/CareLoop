import Foundation
import SwiftData

enum ModelDiscovery {
    static func discover(using llm: any LLMProviding, providerKey: String, context: ModelContext) async {
        do {
            let ids = try await llm.listModels()
            let existing = (try? context.fetch(FetchDescriptor<ModelCatalogEntry>())) ?? []
            for id in ids {
                if existing.contains(where: { $0.providerKey == providerKey && $0.modelID == id }) {
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
                        supportsToolCall: false,
                        supportsReasoning: false,
                        inputPrice: 0,
                        outputPrice: 0,
                        knowledgeCutoff: "",
                        source: .discovered,
                        metadataUnknown: true
                    )
                )
            }
            try? context.save()
        } catch {
            // 静默：发现失败不阻塞使用
        }
    }
}
