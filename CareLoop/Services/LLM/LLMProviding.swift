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

struct LLMToolDefinition: Sendable {
    var name: String
    var description: String
    var parametersJSON: String
}

struct LLMToolCall: Sendable {
    var id: String
    var name: String
    var argumentsJSON: String
}

struct LLMChatMessage: Sendable {
    var role: String
    var content: String?
    var toolCallID: String?
    var toolCalls: [LLMToolCall]
}

struct LLMConversationRequest: Sendable {
    var system: String
    var messages: [LLMChatMessage]
    var tools: [LLMToolDefinition]
    var maxTokens: Int?
}

struct LLMConversationResponse: Sendable {
    var message: LLMChatMessage
    var modelID: String
    var finishReason: String?
}

/// 流式对话事件：文本增量、本轮拼接完成的工具调用、收尾。
enum LLMStreamEvent: Sendable {
    case textDelta(String)
    case toolCalls([LLMToolCall])
    case finished(LLMConversationResponse)
}

protocol LLMProviding: Sendable {
    var supportsVision: Bool { get }
    var supportsToolCall: Bool { get }
    func complete(prompt: LLMPrompt) async throws -> LLMCompletion
    func completeConversation(_ request: LLMConversationRequest) async throws -> LLMConversationResponse
    func streamConversation(_ request: LLMConversationRequest) -> AsyncThrowingStream<LLMStreamEvent, Error>
    func listModels() async throws -> [String]
    func ping(modelID: String) async throws -> TimeInterval
}

extension LLMProviding {
    var supportsToolCall: Bool { false }

    /// 默认实现：不支持流式的 Provider 一次性回放完整结果。
    func streamConversation(_ request: LLMConversationRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await completeConversation(request)
                    if let text = response.message.content, !text.isEmpty {
                        continuation.yield(.textDelta(text))
                    }
                    if !response.message.toolCalls.isEmpty {
                        continuation.yield(.toolCalls(response.message.toolCalls))
                    }
                    continuation.yield(.finished(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func completeConversation(_ request: LLMConversationRequest) async throws -> LLMConversationResponse {
        let history = request.messages.map { msg -> String in
            if msg.role == "tool", let id = msg.toolCallID {
                return "[tool:\(id)] \(msg.content ?? "")"
            }
            if !msg.toolCalls.isEmpty {
                let calls = msg.toolCalls.map { "\($0.name)(\($0.argumentsJSON))" }.joined(separator: "; ")
                return "[assistant-tools] \(calls)"
            }
            return "[\(msg.role)] \(msg.content ?? "")"
        }.joined(separator: "\n")
        let toolHint = request.tools.isEmpty
            ? ""
            : "\n可用工具：\(request.tools.map(\.name).joined(separator: ", "))（当前 Provider 不支持 tool loop，请直接回答）"
        let prompt = LLMPrompt(
            system: request.system,
            user: history + toolHint + "\n请输出 JSON：{\"reply\":\"...\",\"citedRecipeIDs\":[],\"citedClauseIDs\":[]}",
            images: [],
            maxTokens: request.maxTokens
        )
        let completion = try await complete(prompt: prompt)
        return LLMConversationResponse(
            message: LLMChatMessage(role: "assistant", content: completion.text, toolCallID: nil, toolCalls: []),
            modelID: completion.modelID,
            finishReason: "stop"
        )
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
