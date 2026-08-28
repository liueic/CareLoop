import Foundation

struct OpenAICompatibleProvider: LLMProviding {
    var name: String
    var baseURL: URL
    var apiKey: String
    var modelID: String
    var supportsVision: Bool
    var supportsToolCall: Bool

    init(
        name: String,
        baseURL: URL,
        apiKey: String,
        modelID: String,
        supportsVision: Bool,
        supportsToolCall: Bool = true
    ) {
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelID = modelID
        self.supportsVision = supportsVision
        self.supportsToolCall = supportsToolCall
    }

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
        let payload = OpenAIToolChatRequest(
            model: modelID,
            messages: buildMessages(system: request.system, messages: request.messages),
            tools: request.tools.isEmpty ? nil : request.tools.map { tool in
                OpenAIToolChatRequest.Tool(
                    type: "function",
                    function: .init(
                        name: tool.name,
                        description: tool.description,
                        parameters: tool.parametersJSON
                    )
                )
            },
            max_tokens: request.maxTokens ?? 700,
            temperature: 0.35
        )
        let data = try await post(path: "chat/completions", body: payload)
        let decoded = try JSONDecoder().decode(OpenAIToolChatResponse.self, from: data)
        guard let choice = decoded.choices?.first, let message = choice.message else {
            throw LLMError.invalidResponse
        }
        let toolCalls = (message.tool_calls ?? []).map { call in
            LLMToolCall(
                id: call.id ?? UUID().uuidString,
                name: call.function?.name ?? "",
                argumentsJSON: call.function?.arguments ?? "{}"
            )
        }
        return LLMConversationResponse(
            message: LLMChatMessage(
                role: message.role ?? "assistant",
                content: message.content,
                toolCallID: nil,
                toolCalls: toolCalls
            ),
            modelID: modelID,
            finishReason: choice.finish_reason
        )
    }

    func listModels() async throws -> [String] {
        if apiKey.isEmpty { throw LLMError.missingKey }
        let data = try await get(path: "models")
        let decoded = try JSONDecoder().decode(OpenAIModelList.self, from: data)
        return decoded.data.map(\.id)
    }

    func ping(modelID: String) async throws -> TimeInterval {
        let started = Date()
        let payload = OpenAIToolChatRequest(
            model: modelID,
            messages: [.init(role: "user", content: .text("ping"))],
            tools: nil,
            max_tokens: 1,
            temperature: 0
        )
        _ = try await post(path: "chat/completions", body: payload)
        return Date().timeIntervalSince(started)
    }

    private func buildMessages(system: String, messages: [LLMChatMessage]) -> [OpenAIToolChatRequest.Message] {
        var built: [OpenAIToolChatRequest.Message] = [.init(role: "system", content: .text(system))]
        for message in messages {
            switch message.role {
            case "tool":
                built.append(
                    .init(
                        role: "tool",
                        content: .text(message.content ?? ""),
                        tool_call_id: message.toolCallID
                    )
                )
            case "assistant":
                if message.toolCalls.isEmpty {
                    built.append(.init(role: "assistant", content: .text(message.content ?? "")))
                } else {
                    built.append(
                        .init(
                            role: "assistant",
                            content: message.content.map { .text($0) },
                            tool_calls: message.toolCalls.map { call in
                                .init(
                                    id: call.id,
                                    type: "function",
                                    function: .init(name: call.name, arguments: call.argumentsJSON)
                                )
                            }
                        )
                    )
                }
            default:
                built.append(.init(role: message.role, content: .text(message.content ?? "")))
            }
        }
        return built
    }

    private func post<Body: Encodable>(path: String, body: Body) async throws -> Data {
        var request = try makeRequest(path: path)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func get(path: String) async throws -> Data {
        var request = try makeRequest(path: path)
        request.httpMethod = "GET"
        return try await send(request)
    }

    private func makeRequest(path: String) throws -> URLRequest {
        let root = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(root)/\(path)") else { throw LLMError.network("无效的 Base URL") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw LLMError.network("HTTP \(http.statusCode) \(body)")
            }
            return data
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.network(error.localizedDescription)
        }
    }
}

private struct OpenAIToolChatRequest: Encodable {
    var model: String
    var messages: [Message]
    var tools: [Tool]?
    var max_tokens: Int
    var temperature: Double

    struct Tool: Encodable {
        var type: String
        var function: Function

        struct Function: Encodable {
            var name: String
            var description: String
            var parameters: String

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(name, forKey: .name)
                try container.encode(description, forKey: .description)
                if let data = parameters.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) {
                    try container.encode(AnyEncodable(object), forKey: .parameters)
                } else {
                    try container.encode(["type": "object"], forKey: .parameters)
                }
            }

            enum CodingKeys: String, CodingKey {
                case name, description, parameters
            }
        }
    }

    struct Message: Encodable {
        var role: String
        var content: Content?
        var tool_call_id: String?
        var tool_calls: [ToolCall]?

        enum Content: Encodable {
            case text(String)

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .text(let text):
                    try container.encode(text)
                }
            }
        }

        struct ToolCall: Encodable {
            var id: String
            var type: String
            var function: FunctionCall

            struct FunctionCall: Encodable {
                var name: String
                var arguments: String
            }
        }
    }
}

private struct OpenAIToolChatResponse: Decodable {
    var choices: [Choice]?

    struct Choice: Decodable {
        var message: Message?
        var finish_reason: String?

        struct Message: Decodable {
            var role: String?
            var content: String?
            var tool_calls: [ToolCall]?

            struct ToolCall: Decodable {
                var id: String?
                var function: Function?

                struct Function: Decodable {
                    var name: String?
                    var arguments: String?
                }
            }
        }
    }
}

private struct AnyEncodable: Encodable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let value as String:
            try container.encode(value)
        case let value as Int:
            try container.encode(value)
        case let value as Double:
            try container.encode(value)
        case let value as Bool:
            try container.encode(value)
        case let value as [String: Any]:
            try container.encode(value.mapValues(AnyEncodable.init))
        case let value as [Any]:
            try container.encode(value.map(AnyEncodable.init))
        default:
            try container.encode(String(describing: value))
        }
    }
}
