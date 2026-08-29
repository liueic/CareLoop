import Foundation
@testable import CareLoop
import Testing

/// D 层（可选 live 冒烟）：对真实 OpenAI 兼容端点跑一轮流式 + 工具调用。
/// 默认跳过；需要时设置环境变量：
///   CARELOOP_LIVE_BASE_URL=https://api.deepseek.com/v1
///   CARELOOP_LIVE_API_KEY=sk-...
///   CARELOOP_LIVE_MODEL=deepseek-chat
/// 再运行本测试（xcodebuild test 或 Xcode 里单独跑）。
struct LiveStreamingSmokeTests {
    private static var liveEnabled: Bool {
        LiveStreamingConfig.current != nil
    }

    @Test(.enabled(if: liveEnabled))
    func streamingToolLoopAgainstLiveEndpoint() async throws {
        let config = try #require(LiveStreamingConfig.current)
        let provider = OpenAIProvider(
            name: "live",
            baseURL: config.baseURL,
            apiKey: config.apiKey,
            modelID: config.model,
            supportsVision: false
        )

        let tool = LLMToolDefinition(
            name: "get_weather",
            description: "查询城市天气",
            parametersJSON: #"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}"#
        )

        struct Probe: Sendable {
            var sawText = false
            var sawToolCall = false
            var finishReason: String?
        }

        let probe = try await withTimeout(seconds: 60) {
            var result = Probe()
            for try await event in provider.streamConversation(
                LLMConversationRequest(
                    system: "你是测试助手，必须先调用工具再回答。",
                    messages: [LLMChatMessage(role: "user", content: "北京今天天气怎么样？", toolCallID: nil, toolCalls: [])],
                    tools: [tool],
                    maxTokens: 300
                )
            ) {
                switch event {
                case .textDelta(let delta):
                    if !delta.isEmpty { result.sawText = true }
                case .toolCalls:
                    result.sawToolCall = true
                case .finished(let finished):
                    result.finishReason = finished.finishReason
                }
            }
            return result
        }
        #expect(probe.sawToolCall || probe.sawText, "真实端点应至少返回工具调用或文本 delta")
    }

    @Test(.enabled(if: liveEnabled))
    func listModelsAgainstLiveEndpoint() async throws {
        let config = try #require(LiveStreamingConfig.current)
        let provider = OpenAIProvider(
            name: "live",
            baseURL: config.baseURL,
            apiKey: config.apiKey,
            modelID: config.model,
            supportsVision: false
        )
        let models = try await provider.listModels()
        #expect(!models.isEmpty)
    }
}

enum LiveStreamingConfig {
    static var current: (baseURL: URL, apiKey: String, model: String)? {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["CARELOOP_LIVE_BASE_URL"],
              let key = env["CARELOOP_LIVE_API_KEY"],
              let model = env["CARELOOP_LIVE_MODEL"],
              let url = URL(string: base), !key.isEmpty
        else { return nil }
        return (url, key, model)
    }
}

/// 简易超时包装：live 端点偶尔卡住时避免测试悬挂。
func withTimeout<T: Sendable>(seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

struct TimeoutError: Error {}
