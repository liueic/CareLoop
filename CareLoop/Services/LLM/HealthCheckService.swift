import Foundation

/// 测活结果：状态 + 延迟（秒）+ 失败原因（成功为 nil）。
/// 原实现把一切失败折叠成 .down 且不透出原因，用户只看到红点无法排查
/// （如本机代理 TLS 失败、401 无效 Key、404 端点无 /models）。
enum HealthCheckService {
    struct Outcome {
        var status: ProviderHealthStatus
        var latency: TimeInterval?
        var message: String?
    }

    /// 测活专用短超时会话：默认 60s 太长，红绿灯检查 15s 足够。
    private static func checkSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }

    static func connectivity(provider: LLMProviderConfig, apiKey: String) async -> Outcome {
        guard let url = URL(string: provider.baseURL) else {
            return Outcome(status: .down, latency: nil, message: "Base URL 无法解析：\(provider.baseURL)")
        }
        guard !apiKey.isEmpty else {
            return Outcome(status: .down, latency: nil, message: "未配置 API Key")
        }
        let llm = OpenAIProvider(
            name: provider.name,
            baseURL: url,
            apiKey: apiKey,
            modelID: "ping",
            supportsVision: false,
            session: checkSession()
        )
        let start = Date()
        do {
            _ = try await llm.listModels()
            let latency = Date().timeIntervalSince(start)
            return Outcome(status: classify(latency), latency: latency, message: nil)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return Outcome(status: .down, latency: nil, message: message)
        }
    }

    static func pingModel(
        provider: LLMProviderConfig,
        apiKey: String,
        modelID: String
    ) async -> Outcome {
        guard let url = URL(string: provider.baseURL) else {
            return Outcome(status: .down, latency: nil, message: "Base URL 无法解析：\(provider.baseURL)")
        }
        guard !apiKey.isEmpty else {
            return Outcome(status: .down, latency: nil, message: "未配置 API Key")
        }
        let llm = OpenAIProvider(
            name: provider.name,
            baseURL: url,
            apiKey: apiKey,
            modelID: modelID,
            supportsVision: false,
            session: checkSession()
        )
        do {
            let latency = try await llm.ping(modelID: modelID)
            return Outcome(status: classify(latency), latency: latency, message: nil)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return Outcome(status: .down, latency: nil, message: message)
        }
    }

    static func classify(_ interval: TimeInterval) -> ProviderHealthStatus {
        if interval < 3 { return .ok }
        if interval < 10 { return .degraded }
        return .down
    }
}
