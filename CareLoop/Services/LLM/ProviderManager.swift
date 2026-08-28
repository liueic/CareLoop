import Foundation
import SwiftData

@MainActor
final class ProviderManager {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func bootstrapIfNeeded() {
        let existing = (try? context.fetch(FetchDescriptor<LLMProviderConfig>())) ?? []
        if existing.isEmpty {
            for preset in PresetProviders.all {
                context.insert(
                    LLMProviderConfig(key: preset.key, name: preset.name, baseURL: preset.baseURL, isPreset: true)
                )
            }
        }
        let catalog = (try? context.fetch(FetchDescriptor<ModelCatalogEntry>())) ?? []
        if catalog.isEmpty {
            for item in BundledModelCatalog.load() {
                context.insert(
                    ModelCatalogEntry(
                        modelID: item.modelID,
                        providerKey: item.providerKey,
                        displayName: item.displayName,
                        contextWindow: item.contextWindow,
                        maxOutputTokens: item.maxOutputTokens,
                        supportsVision: item.supportsVision,
                        supportsToolCall: item.supportsToolCall,
                        supportsReasoning: item.supportsReasoning,
                        inputPrice: item.inputPrice,
                        outputPrice: item.outputPrice,
                        knowledgeCutoff: item.knowledgeCutoff,
                        source: CatalogSource(rawValue: item.source) ?? .bundled
                    )
                )
            }
        }
        try? context.save()
    }

    func providers() -> [LLMProviderConfig] {
        let descriptor = FetchDescriptor<LLMProviderConfig>(sortBy: [SortDescriptor(\.name)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func models(providerKey: String? = nil) -> [ModelCatalogEntry] {
        var descriptor = FetchDescriptor<ModelCatalogEntry>(sortBy: [SortDescriptor(\.displayName)])
        if let providerKey {
            descriptor.predicate = #Predicate { $0.providerKey == providerKey }
        }
        return (try? context.fetch(descriptor)) ?? []
    }

    func upsertCustom(name: String, baseURL: String, key: String) {
        let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
        let config = LLMProviderConfig(key: slug, name: name, baseURL: baseURL, isPreset: false)
        context.insert(config)
        if !key.isEmpty {
            KeychainStore.save(key: config.apiKeyRef, secret: key)
        }
        try? context.save()
    }

    func saveKey(_ secret: String, for config: LLMProviderConfig) {
        KeychainStore.save(key: config.apiKeyRef, secret: secret)
    }

    func key(for config: LLMProviderConfig) -> String {
        KeychainStore.load(key: config.apiKeyRef)
    }

    func delete(_ config: LLMProviderConfig) {
        guard !config.isPreset else { return }
        KeychainStore.delete(key: config.apiKeyRef)
        context.delete(config)
        try? context.save()
    }

    func makeLLM(selection: ActiveModelSelection) -> any LLMProviding {
        guard let provider = providers().first(where: { $0.key == selection.providerKey && $0.enabled }) else {
            return MockLLMProvider()
        }
        let secret = key(for: provider)
        guard !secret.isEmpty, let url = URL(string: provider.baseURL) else {
            return MockLLMProvider()
        }
        let model = models(providerKey: provider.key).first(where: { $0.modelID == selection.modelID })
        return OpenAICompatibleProvider(
            name: provider.name,
            baseURL: url,
            apiKey: secret,
            modelID: selection.modelID,
            supportsVision: model?.supportsVision ?? false
        )
    }
}
