import Foundation

struct LLMPrompt: Sendable {
    var system: String
    var user: String
    var images: [Data]
    var maxTokens: Int? = nil
}

struct LLMCompletion: Sendable {
    var text: String
    var modelID: String
}

enum LLMError: Error, LocalizedError, Sendable {
    case missingKey
    case network(String)
    case invalidResponse
    case visionRequired

    var errorDescription: String? {
        switch self {
        case .missingKey: "未配置 API Key，已改用本地模板。"
        case .network(let message): message
        case .invalidResponse: "模型返回无法解析"
        case .visionRequired: "当前模型不支持看图，请切换到多模态模型"
        }
    }
}

protocol LLMProviding: Sendable {
    var supportsVision: Bool { get }
    func complete(prompt: LLMPrompt) async throws -> LLMCompletion
    func listModels() async throws -> [String]
    func ping(modelID: String) async throws -> TimeInterval
}

struct OpenAIChatRequest: Encodable {
    var model: String
    var messages: [Message]
    var max_tokens: Int?
    var temperature: Double?

    struct Message: Encodable {
        var role: String
        var content: Content

        enum Content: Encodable {
            case text(String)
            case parts([Part])

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .text(let text):
                    try container.encode(text)
                case .parts(let parts):
                    try container.encode(parts)
                }
            }
        }

        struct Part: Encodable {
            var type: String
            var text: String?
            var image_url: ImageURL?

            struct ImageURL: Encodable {
                var url: String
            }
        }
    }
}

struct OpenAIChatResponse: Decodable {
    var choices: [Choice]?
    struct Choice: Decodable {
        var message: Message?
        struct Message: Decodable {
            var content: String?
        }
    }
}

struct OpenAIModelList: Decodable {
    var data: [Item]
    struct Item: Decodable {
        var id: String
    }
}

enum LLMJSON {
    static func object(from text: String) -> [String: Any]? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fenceStart = cleaned.range(of: "```json"),
           let fenceEnd = cleaned.range(of: "```", options: .backwards) {
            cleaned = String(cleaned[fenceStart.upperBound..<fenceEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let fenceStart = cleaned.range(of: "```"),
                  let fenceEnd = cleaned.range(of: "```", options: .backwards),
                  fenceStart.lowerBound != fenceEnd.lowerBound {
            cleaned = String(cleaned[fenceStart.upperBound..<fenceEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = cleaned.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
