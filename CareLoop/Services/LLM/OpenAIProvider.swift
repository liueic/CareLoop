import Foundation
import OpenAI

/// 基于 MacPaw OpenAI SDK 的云端 Provider，支持任意 OpenAI 兼容端点
/// （DeepSeek / 通义千问 / Ollama 等，通过 baseURL 拆分为 host + basePath）。
struct OpenAIProvider: LLMProviding {
    var name: String
    var baseURL: URL
    var apiKey: String
    var modelID: String
    var supportsVision: Bool
    var supportsToolCall: Bool

    private let client: OpenAI

    init(
        name: String,
        baseURL: URL,
        apiKey: String,
        modelID: String,
        supportsVision: Bool,
        supportsToolCall: Bool = true,
        session: URLSession = .shared
    ) {
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelID = modelID
        self.supportsVision = supportsVision
        self.supportsToolCall = supportsToolCall
        self.client = OpenAI(
            configuration: Self.makeConfiguration(baseURL: baseURL, apiKey: apiKey),
            session: session
        )
    }

    // MARK: - LLMProviding

    func complete(prompt: LLMPrompt) async throws -> LLMCompletion {
        let response = try await completeConversation(
            LLMConversationRequest(
                system: prompt.system,
                messages: [LLMChatMessage(role: "user", content: prompt.user, toolCallID: nil, toolCalls: [])],
                tools: [],
                maxTokens: prompt.maxTokens
            )
        )
        return LLMCompletion(text: response.message.content ?? "", modelID: response.modelID)
    }

    func completeConversation(_ request: LLMConversationRequest) async throws -> LLMConversationResponse {
        if apiKey.isEmpty { throw LLMError.missingKey }
        let result: ChatResult
        do {
            result = try await client.chats(query: makeQuery(request))
        } catch {
            throw Self.mapError(error)
        }
        guard let choice = result.choices.first else { throw LLMError.invalidResponse }
        return Self.makeResponse(
            content: choice.message.content,
            toolCalls: (choice.message.toolCalls ?? []).map(Self.makeLLMToolCall),
            finishReason: choice.finishReason,
            modelID: modelID
        )
    }

    func streamConversation(_ request: LLMConversationRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let query = makeQuery(request)
            let task = Task {
                // SSE 里 tool_calls 的参数按 index 分片到达，需要跨 chunk 拼接。
                var text = ""
                struct PartialToolCall {
                    var id: String?
                    var name: String?
                    var arguments = ""
                }
                var toolAccumulator: [Int: PartialToolCall] = [:]
                var finishReason: String?
                do {
                    if apiKey.isEmpty { throw LLMError.missingKey }
                    for try await chunk in client.chatsStream(query: query) {
                        if Task.isCancelled { break }
                        guard let choice = chunk.choices.first else { continue }
                        if let deltaText = choice.delta.content, !deltaText.isEmpty {
                            text += deltaText
                            continuation.yield(.textDelta(deltaText))
                        }
                        for fragment in choice.delta.toolCalls ?? [] {
                            var partial = toolAccumulator[fragment.index] ?? PartialToolCall(id: nil, name: nil)
                            if let id = fragment.id { partial.id = id }
                            if let fragmentName = fragment.function?.name { partial.name = fragmentName }
                            if let args = fragment.function?.arguments { partial.arguments += args }
                            toolAccumulator[fragment.index] = partial
                        }
                        if let reason = choice.finishReason {
                            finishReason = reason.rawValue
                        }
                    }
                    let calls = toolAccumulator
                        .sorted(by: { $0.key < $1.key })
                        .map { _, partial in
                            LLMToolCall(
                                id: partial.id ?? UUID().uuidString,
                                name: partial.name ?? "",
                                argumentsJSON: partial.arguments
                            )
                        }
                    if !calls.isEmpty {
                        continuation.yield(.toolCalls(calls))
                    }
                    continuation.yield(
                        .finished(
                            Self.makeResponse(
                                content: text.isEmpty ? nil : text,
                                toolCalls: calls,
                                finishReason: finishReason,
                                modelID: modelID
                            )
                        )
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels() async throws -> [String] {
        if apiKey.isEmpty { throw LLMError.missingKey }
        do {
            let result = try await client.models()
            return result.data.map(\.id)
        } catch {
            throw Self.mapError(error)
        }
    }

    func ping(modelID: String) async throws -> TimeInterval {
        let started = Date()
        // 不传 temperature：部分端点（o1 类）拒绝显式 temperature，测活只关心连通性。
        var query = ChatQuery(
            messages: [.user(.init(content: .string("ping")))],
            model: modelID
        )
        query.maxTokens = 1
        _ = try await client.chats(query: query)
        return Date().timeIntervalSince(started)
    }

    // MARK: - 映射

    private func makeQuery(_ request: LLMConversationRequest) -> ChatQuery {
        var built: [ChatQuery.ChatCompletionMessageParam] = [
            .system(.init(content: .textContent(request.system)))
        ]
        for message in request.messages {
            let role = ChatQuery.ChatCompletionMessageParam.Role(rawValue: message.role) ?? .user
            if let mapped = ChatQuery.ChatCompletionMessageParam(
                role: role,
                content: message.content,
                toolCalls: message.toolCalls.map(Self.makeSDKToolCall),
                toolCallId: message.toolCallID
            ) {
                built.append(mapped)
            }
        }
        var query = ChatQuery(
            messages: built,
            model: modelID,
            temperature: 0.35,
            tools: request.tools.isEmpty ? nil : request.tools.map(Self.makeSDKTool)
        )
        // 刻意使用已废弃的 max_tokens 而非 max_completion_tokens：
        // DeepSeek / 通义 / Ollama 等兼容端点目前只识别 max_tokens。
        // 默认 4096：qwen3 系等思考型模型的 reasoning_content 优先消耗预算，
        // 太小（如 700）会被思考吃光导致 content 为空，Agent 只能走降级回复。
        query.maxTokens = request.maxTokens ?? 4096
        return query
    }

    private static func makeSDKTool(_ tool: LLMToolDefinition) -> ChatQuery.ChatCompletionToolParam {
        let schema = tool.parametersJSON
            .data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(JSONSchema.self, from: $0) }
        return .init(
            function: .init(name: tool.name, description: tool.description, parameters: schema)
        )
    }

    private static func makeSDKToolCall(_ call: LLMToolCall) -> ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam {
        .init(id: call.id, function: .init(arguments: call.argumentsJSON, name: call.name))
    }

    private static func makeLLMToolCall(
        from call: ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam
    ) -> LLMToolCall {
        LLMToolCall(id: call.id, name: call.function.name, argumentsJSON: call.function.arguments)
    }

    private static func makeResponse(
        content: String?,
        toolCalls: [LLMToolCall],
        finishReason: String?,
        modelID: String
    ) -> LLMConversationResponse {
        LLMConversationResponse(
            message: LLMChatMessage(role: "assistant", content: content, toolCallID: nil, toolCalls: toolCalls),
            modelID: modelID,
            finishReason: finishReason
        )
    }

    static func makeConfiguration(baseURL: URL, apiKey: String) -> OpenAI.Configuration {
        let scheme = baseURL.scheme ?? "https"
        let host = baseURL.host ?? baseURL.absoluteString
        let port = baseURL.port ?? (scheme == "http" ? 80 : 443)
        // 端点未带路径、或只写了根斜杠（"https://host/"）时按 OpenAI 兼容惯例补 /v1；
        // 显式路径去掉尾部斜杠（SDK 会按斜杠拆分再 join，避免 "/v1/" 产生歧义）。
        var path = baseURL.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        if path.count <= 1 {
            path = "/v1"
        }
        return OpenAI.Configuration(
            token: apiKey.isEmpty ? nil : apiKey,
            host: host,
            port: port,
            scheme: scheme,
            basePath: path,
            timeoutInterval: 60
        )
    }

    private static func mapError(_ error: Error) -> LLMError {
        if let llmError = error as? LLMError { return llmError }
        if let openAIError = error as? OpenAIError {
            switch openAIError {
            case .emptyData:
                return .invalidResponse
            case .statusError(_, let statusCode):
                return .network("HTTP \(statusCode)")
            }
        }
        // APIError（服务端返回的错误体）本身是 LocalizedError，message 会透传。
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return .network(message)
    }
}
