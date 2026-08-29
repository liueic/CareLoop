import Foundation
import Testing

@testable import CareLoop

/// baseURL → OpenAI SDK Configuration 的规范化：
/// 无路径/根斜杠补 /v1，显式路径去尾斜杠，自定义完整路径保留。
struct OpenAIProviderConfigurationTests {
    @Test func emptyPathGetsV1() {
        let config = OpenAIProvider.makeConfiguration(
            baseURL: URL(string: "https://api.deepseek.com")!,
            apiKey: "sk-test"
        )
        #expect(config.basePath == "/v1")
        #expect(config.host == "api.deepseek.com")
        #expect(config.scheme == "https")
    }

    @Test func rootSlashTreatedAsEmpty() {
        // 旧 bug：path == "/" 时不补 /v1，SDK 拼出根路径 /models → 404
        let config = OpenAIProvider.makeConfiguration(
            baseURL: URL(string: "https://api.deepseek.com/")!,
            apiKey: "sk-test"
        )
        #expect(config.basePath == "/v1")
    }

    @Test func trailingSlashTrimmed() {
        let config = OpenAIProvider.makeConfiguration(
            baseURL: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/")!,
            apiKey: "sk-test"
        )
        #expect(config.basePath == "/compatible-mode/v1")
    }

    @Test func explicitPathPreserved() {
        // 火山方舟等非 /v1 前缀的完整路径原样保留
        let config = OpenAIProvider.makeConfiguration(
            baseURL: URL(string: "https://ark.cn-beijing.volces.com/api/v3")!,
            apiKey: "sk-test"
        )
        #expect(config.basePath == "/api/v3")
    }

    @Test func localhostWithPortAndHTTP() {
        let config = OpenAIProvider.makeConfiguration(
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            apiKey: ""
        )
        #expect(config.scheme == "http")
        #expect(config.host == "127.0.0.1")
        #expect(config.port == 11434)
        #expect(config.basePath == "/v1")
        // 空 Key 时 token 为 nil（本地端点常见）
        #expect(config.token == nil)
    }

    @Test func nonEmptyKeyBecomesToken() {
        let config = OpenAIProvider.makeConfiguration(
            baseURL: URL(string: "https://api.openai.com/v1")!,
            apiKey: "sk-abc"
        )
        #expect(config.token == "sk-abc")
    }
}
