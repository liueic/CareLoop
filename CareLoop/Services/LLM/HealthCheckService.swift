import Foundation

enum HealthCheckService {
    static func connectivity(provider: LLMProviderConfig, apiKey: String) async -> (ProviderHealthStatus, TimeInterval?) {
        guard let url = URL(string: provider.baseURL) else { return (.down, nil) }
        let llm = OpenAICompatibleProvider(
            name: provider.name,
            baseURL: url,
            apiKey: apiKey,
            modelID: "ping",
            supportsVision: false
        )
        let start = Date()
        do {
            _ = try await llm.listModels()
            let ms = Date().timeIntervalSince(start)
            return (classify(ms), ms)
        } catch {
            return (.down, nil)
        }
    }

    static func pingModel(
        provider: LLMProviderConfig,
        apiKey: String,
        modelID: String
    ) async -> (ProviderHealthStatus, TimeInterval?) {
        guard let url = URL(string: provider.baseURL) else { return (.down, nil) }
        let llm = OpenAICompatibleProvider(
            name: provider.name,
            baseURL: url,
            apiKey: apiKey,
            modelID: modelID,
            supportsVision: false
        )
        do {
            let interval = try await llm.ping(modelID: modelID)
            return (classify(interval), interval)
        } catch {
            return (.down, nil)
        }
    }

    static func classify(_ interval: TimeInterval) -> ProviderHealthStatus {
        if interval < 3 { return .ok }
        if interval < 10 { return .degraded }
        return .down
    }
}
