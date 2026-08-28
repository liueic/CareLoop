import Foundation

enum BundledModelCatalog {
    struct Snapshot: Codable, Sendable {
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
        var source: String
    }

    static func load() -> [Snapshot] {
        Bundle.main.decodeJSON("model_catalog") ?? []
    }
}

enum PresetProviders {
    static let all: [(key: String, name: String, baseURL: String)] = [
        ("deepseek", "DeepSeek", "https://api.deepseek.com/v1"),
        ("qwen", "通义千问", "https://dashscope.aliyuncs.com/compatible-mode/v1"),
        ("doubao", "豆包 / 火山方舟", "https://ark.cn-beijing.volces.com/api/v3"),
        ("zhipu", "智谱 GLM", "https://open.bigmodel.cn/api/paas/v4"),
        ("openrouter", "OpenRouter", "https://openrouter.ai/api/v1"),
        ("openai", "OpenAI", "https://api.openai.com/v1"),
    ]
}
