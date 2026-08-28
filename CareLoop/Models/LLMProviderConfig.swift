import Foundation
import SwiftData

@Model
final class LLMProviderConfig {
    var id: UUID
    var key: String
    var name: String
    var baseURL: String
    var providerType: String
    var isPreset: Bool
    var enabled: Bool
    var apiKeyRef: String
    var lastHealthAt: Date?
    var healthStatusRaw: String
    var lastLatencyMS: Double?

    init(
        key: String,
        name: String,
        baseURL: String,
        isPreset: Bool,
        enabled: Bool = true
    ) {
        self.id = UUID()
        self.key = key
        self.name = name
        self.baseURL = baseURL
        self.providerType = "openaiCompatible"
        self.isPreset = isPreset
        self.enabled = enabled
        self.apiKeyRef = "careloop.llm.\(key)"
        self.healthStatusRaw = ProviderHealthStatus.unknown.rawValue
    }

    var healthStatus: ProviderHealthStatus {
        get { ProviderHealthStatus(rawValue: healthStatusRaw) ?? .unknown }
        set { healthStatusRaw = newValue.rawValue }
    }
}

@Model
final class ModelCatalogEntry {
    var id: UUID
    var modelID: String
    var providerKey: String
    var displayName: String
    var contextWindow: Int
    var maxOutputTokens: Int
    var supportsVision: Bool
    var supportsToolCall: Bool
    var supportsReasoning: Bool
    var inputPrice: Double
    var outputPrice: Double
    var knowledgeCutoff: String
    var sourceRaw: String
    var lastSyncedAt: Date?
    var metadataUnknown: Bool
    var lastPingStatusRaw: String
    var lastPingAt: Date?
    var lastPingMS: Double?

    init(
        modelID: String,
        providerKey: String,
        displayName: String,
        contextWindow: Int,
        maxOutputTokens: Int,
        supportsVision: Bool,
        supportsToolCall: Bool,
        supportsReasoning: Bool,
        inputPrice: Double,
        outputPrice: Double,
        knowledgeCutoff: String,
        source: CatalogSource,
        metadataUnknown: Bool = false
    ) {
        self.id = UUID()
        self.modelID = modelID
        self.providerKey = providerKey
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsVision = supportsVision
        self.supportsToolCall = supportsToolCall
        self.supportsReasoning = supportsReasoning
        self.inputPrice = inputPrice
        self.outputPrice = outputPrice
        self.knowledgeCutoff = knowledgeCutoff
        self.sourceRaw = source.rawValue
        self.metadataUnknown = metadataUnknown
        self.lastPingStatusRaw = ProviderHealthStatus.unknown.rawValue
    }

    var source: CatalogSource {
        get { CatalogSource(rawValue: sourceRaw) ?? .bundled }
        set { sourceRaw = newValue.rawValue }
    }

    var lastPingStatus: ProviderHealthStatus {
        get { ProviderHealthStatus(rawValue: lastPingStatusRaw) ?? .unknown }
        set { lastPingStatusRaw = newValue.rawValue }
    }
}

struct ActiveModelSelection: Codable, Hashable, Sendable {
    var providerKey: String
    var modelID: String

    static let storageKey = "careloop.activeModel"
}
