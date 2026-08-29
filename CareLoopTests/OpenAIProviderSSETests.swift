import Foundation
import Network
@testable import CareLoop
import Testing

/// B 层端到端：测试内起的本地回环 HTTP 服务器输出脚本化 SSE 流，
/// MacPaw OpenAI SDK 走真实的 URLSession 网络栈消费，
/// 验证 OpenAIProvider 的 delta 拼接（文本重组 + 跨 chunk 工具参数聚合）。
///
/// 不用 URLProtocol 拦截：SDK 的流式路径自建 URLSession，
/// 全局注册对自定义 session 无效，只有真服务器能同时覆盖两条路径。
final class LocalSSEServer: @unchecked Sendable {
    private let listener: NWListener
    private let response: Data
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "careloop.sse-test-server")

    init(status: Int, contentType: String, body: String) throws {
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
        response = Data(head.utf8) + Data(body.utf8)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    var port: UInt16 {
        listener.port?.rawValue ?? 0
    }

    func start() throws {
        let semaphore = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed:
                semaphore.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            // 回调本就运行在 listener 的 queue 上，直接操作即可（queue.sync 会死锁）。
            self.connections.append(connection)
            connection.start(queue: self.queue)
            // 读完请求头即可回 canned 响应；无需解析。
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                connection.send(content: self.response, completion: .contentProcessed { _ in
                    // 稍等确保对端收完再关闭。
                    self.queue.asyncAfter(deadline: .now() + 0.2) {
                        connection.cancel()
                    }
                })
            }
        }
        listener.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 5)
        guard port != 0 else {
            throw NSError(domain: "SSEServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "服务器未就绪"])
        }
    }

    func stop() {
        listener.cancel()
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}

struct OpenAIProviderSSETests {
    /// 每个测试独享服务器与响应，避免共享状态在并行测试间竞态。
    private func makeProvider(body: String, status: Int = 200) throws -> (OpenAIProvider, LocalSSEServer) {
        let server = try LocalSSEServer(status: status, contentType: "text/event-stream", body: body)
        try server.start()
        let provider = OpenAIProvider(
            name: "local",
            baseURL: URL(string: "http://127.0.0.1:\(server.port)/v1")!,
            apiKey: "test-key",
            modelID: "stub-model",
            supportsVision: false
        )
        return (provider, server)
    }

    private func chunk(deltaJSON: String, finish: String? = nil) -> String {
        let finishPart = finish.map { ",\"finish_reason\":\"\($0)\"" } ?? ",\"finish_reason\":null"
        return "data: {\"id\":\"c1\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"stub-model\",\"choices\":[{\"index\":0,\"delta\":"
            + deltaJSON + finishPart + "}]}" + "\n\n"
    }

    private let done = "data: [DONE]" + "\n\n"

    // MARK: 工具调用分片的确定性构造（手写转义容易出错，用代码拼）

    private func jsonString(_ raw: String) -> String {
        "\"" + raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func toolFragment(index: Int, id: String?, name: String?, argsDelta: String) -> String {
        var parts = ["\"index\":\(index)"]
        if let id {
            parts.append("\"id\":\(jsonString(id))")
        }
        var function: [String] = []
        if let name {
            function.append("\"name\":\(jsonString(name))")
        }
        function.append("\"arguments\":\(jsonString(argsDelta))")
        parts.append("\"function\":{\(function.joined(separator: ","))}")
        return #"{"tool_calls":[{\#(parts.joined(separator: ","))}]}"#
    }

    @Test func streamedTextAndFragmentedToolCallsReassemble() async throws {
        // 工具调用分片：name 只在首片出现，arguments 跨三片拼成完整 JSON。
        let (provider, server) = try makeProvider(body:
            chunk(deltaJSON: #"{"role":"assistant","content":""}"#) +
            chunk(deltaJSON: toolFragment(index: 0, id: "call_1", name: "filter_safe_recipes", argsDelta: "{\"li")) +
            chunk(deltaJSON: toolFragment(index: 0, id: nil, name: nil, argsDelta: "mit\":")) +
            chunk(deltaJSON: toolFragment(index: 0, id: nil, name: nil, argsDelta: "8}"), finish: "tool_calls") +
            done
        )
        defer { server.stop() }

        var text = ""
        var toolCalls: [LLMToolCall] = []
        var finishReason: String?
        for try await event in provider.streamConversation(
            LLMConversationRequest(
                system: "s",
                messages: [LLMChatMessage(role: "user", content: "今晚吃什么", toolCallID: nil, toolCalls: [])],
                tools: [
                    LLMToolDefinition(
                        name: "filter_safe_recipes",
                        description: "d",
                        parametersJSON: #"{"type":"object","properties":{"limit":{"type":"integer"}}}"#
                    )
                ],
                maxTokens: 100
            )
        ) {
            switch event {
            case .textDelta(let delta): text += delta
            case .toolCalls(let calls): toolCalls = calls
            case .finished(let response): finishReason = response.finishReason
            }
        }

        #expect(toolCalls.count == 1)
        #expect(toolCalls[0].id == "call_1")
        #expect(toolCalls[0].name == "filter_safe_recipes")
        #expect(toolCalls[0].argumentsJSON == #"{"limit":8}"#)
        #expect(finishReason == "tool_calls")
        #expect(text.isEmpty)
    }

    @Test func streamedPlainTextReassembles() async throws {
        let (provider, server) = try makeProvider(body:
            chunk(deltaJSON: #"{"content":"今晚"}"#) +
            chunk(deltaJSON: #"{"content":"可以试试"}"#) +
            chunk(deltaJSON: #"{"content":"清蒸鲈鱼"}"#, finish: "stop") +
            done
        )
        defer { server.stop() }

        var deltas: [String] = []
        var finalContent: String?
        for try await event in provider.streamConversation(
            LLMConversationRequest(
                system: "s",
                messages: [LLMChatMessage(role: "user", content: "hi", toolCallID: nil, toolCalls: [])],
                tools: [],
                maxTokens: 50
            )
        ) {
            switch event {
            case .textDelta(let delta): deltas.append(delta)
            case .toolCalls: break
            case .finished(let response): finalContent = response.message.content
            }
        }
        #expect(deltas.joined() == "今晚可以试试清蒸鲈鱼")
        #expect(finalContent == "今晚可以试试清蒸鲈鱼")
    }

    @Test func blockingConversationDecodesToolCalls() async throws {
        let body = """
        {"id":"c1","object":"chat.completion","created":1,"model":"stub-model","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_9","function":{"name":"lookup_diet_clauses","arguments":"{\\"query\\":\\"少盐\\"}"}}]},"finish_reason":"tool_calls"}]}
        """
        let (provider, server) = try makeProvider(body: body)
        defer { server.stop() }
        let response = try await provider.completeConversation(
            LLMConversationRequest(
                system: "s",
                messages: [LLMChatMessage(role: "user", content: "q", toolCallID: nil, toolCalls: [])],
                tools: [],
                maxTokens: 50
            )
        )
        #expect(response.message.toolCalls.count == 1)
        #expect(response.message.toolCalls[0].name == "lookup_diet_clauses")
        #expect(response.finishReason == "tool_calls")
    }

    @Test func httpErrorSurfacesAsNetworkError() async throws {
        let (provider, server) = try makeProvider(
            body: #"{"error":{"message":"bad key","type":"invalid_request_error","param":null,"code":null}}"#,
            status: 401
        )
        defer { server.stop() }
        do {
            _ = try await provider.completeConversation(
                LLMConversationRequest(
                    system: "s",
                    messages: [LLMChatMessage(role: "user", content: "q", toolCallID: nil, toolCalls: [])],
                    tools: [],
                    maxTokens: 50
                )
            )
            Issue.record("401 应抛出错误")
        } catch {
            #expect(error is LLMError)
        }
    }
}
