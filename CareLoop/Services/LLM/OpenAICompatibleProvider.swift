import Foundation

struct OpenAICompatibleProvider: LLMProviding {
    var name: String
    var baseURL: URL
    var apiKey: String
    var modelID: String
    var supportsVision: Bool

    func complete(prompt: LLMPrompt) async throws -> LLMCompletion {
        if apiKey.isEmpty { throw LLMError.missingKey }
        if !prompt.images.isEmpty && !supportsVision { throw LLMError.visionRequired }
        var messages: [OpenAIChatRequest.Message] = [
            .init(role: "system", content: .text(prompt.system)),
        ]
        if prompt.images.isEmpty {
            messages.append(.init(role: "user", content: .text(prompt.user)))
        } else {
            var parts: [OpenAIChatRequest.Message.Part] = [
                .init(type: "text", text: prompt.user, image_url: nil),
            ]
            for data in prompt.images {
                let b64 = data.base64EncodedString()
                parts.append(
                    .init(
                        type: "image_url",
                        text: nil,
                        image_url: .init(url: "data:image/jpeg;base64,\(b64)")
                    )
                )
            }
            messages.append(.init(role: "user", content: .parts(parts)))
        }
        let payload = OpenAIChatRequest(model: modelID, messages: messages, max_tokens: prompt.maxTokens ?? 600, temperature: 0.4)
        let data = try await post(path: "chat/completions", body: payload)
        let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        guard let text = decoded.choices?.first?.message?.content, !text.isEmpty else {
            throw LLMError.invalidResponse
        }
        return LLMCompletion(text: text, modelID: modelID)
    }

    func listModels() async throws -> [String] {
        if apiKey.isEmpty { throw LLMError.missingKey }
        let data = try await get(path: "models")
        let decoded = try JSONDecoder().decode(OpenAIModelList.self, from: data)
        return decoded.data.map(\.id)
    }

    func ping(modelID: String) async throws -> TimeInterval {
        let started = Date()
        let payload = OpenAIChatRequest(
            model: modelID,
            messages: [.init(role: "user", content: .text("ping"))],
            max_tokens: 1,
            temperature: 0
        )
        _ = try await post(path: "chat/completions", body: payload)
        return Date().timeIntervalSince(started)
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
        request.timeoutInterval = 20
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
