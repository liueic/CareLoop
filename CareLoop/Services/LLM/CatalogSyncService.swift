import Foundation
import SwiftData

enum CatalogSyncService {
    static let modelsDevURL = URL(string: "https://models.dev/api.json")!

    static func syncIfNeeded(context: ModelContext, force: Bool = false) async {
        let existing = (try? context.fetch(FetchDescriptor<ModelCatalogEntry>())) ?? []
        if let last = existing.compactMap(\.lastSyncedAt).max(),
           Date().timeIntervalSince(last) < 7 * 24 * 3600,
           !force {
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: modelsDevURL)
            try merge(data: data, into: context)
        } catch {
            // 失败沿用快照
        }
    }

    static func merge(data: Data, into context: ModelContext) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let providers = (root["providers"] as? [String: Any]) ?? root
        let existing = (try? context.fetch(FetchDescriptor<ModelCatalogEntry>())) ?? []
        for (providerKey, value) in providers {
            guard let provider = value as? [String: Any] else { continue }
            let models = (provider["models"] as? [String: Any]) ?? [:]
            for (modelID, raw) in models {
                guard let model = raw as? [String: Any] else { continue }
                let name = (model["name"] as? String) ?? modelID
                let limit = model["limit"] as? [String: Any]
                let contextWindow = intValue(limit?["context"]) ?? intValue(model["context"]) ?? 0
                let maxOut = intValue(limit?["output"]) ?? 0
                let modalities = model["modalities"] as? [String: Any]
                let inputs = (modalities?["input"] as? [String]) ?? []
                let vision = inputs.contains("image") || (model["attachment"] as? Bool == true)
                let cost = model["cost"] as? [String: Any]
                let inputPrice = doubleValue(cost?["input"]) ?? 0
                let outputPrice = doubleValue(cost?["output"]) ?? 0
                if let found = existing.first(where: { $0.providerKey == mappedProvider(providerKey) && $0.modelID == modelID }) {
                    found.displayName = name
                    found.contextWindow = contextWindow
                    found.maxOutputTokens = maxOut
                    found.supportsVision = vision
                    found.inputPrice = inputPrice
                    found.outputPrice = outputPrice
                    found.source = .synced
                    found.lastSyncedAt = Date()
                    found.metadataUnknown = false
                } else {
                    let entry = ModelCatalogEntry(
                        modelID: modelID,
                        providerKey: mappedProvider(providerKey),
                        displayName: name,
                        contextWindow: contextWindow,
                        maxOutputTokens: maxOut,
                        supportsVision: vision,
                        supportsToolCall: false,
                        supportsReasoning: false,
                        inputPrice: inputPrice,
                        outputPrice: outputPrice,
                        knowledgeCutoff: "",
                        source: .synced
                    )
                    entry.lastSyncedAt = Date()
                    context.insert(entry)
                }
            }
        }
        try? context.save()
    }

    private static func mappedProvider(_ key: String) -> String {
        switch key.lowercased() {
        case "alibaba", "dashscope", "qwen": "qwen"
        case "volcengine", "byteplus", "doubao": "doubao"
        case "zhipuai", "zai": "zhipu"
        default: key.lowercased()
        }
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? Double { return Int(n) }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let n = any as? Double { return n }
        if let n = any as? Int { return Double(n) }
        if let s = any as? String { return Double(s) }
        return nil
    }
}
