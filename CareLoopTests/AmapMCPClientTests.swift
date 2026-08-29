import Foundation
import Network
@testable import CareLoop
import Testing

/// 本地回环 MCP 服务器：解析真实的 JSON-RPC over HTTP 请求（Streamable HTTP 形态），
/// 按方法回放脚本化响应。swift-sdk 的 HTTPClientTransport 走真实 URLSession 网络栈，
/// 验证 AmapMCPClient 的 initialize 握手 → tools/call → 文本提取 → 错误映射全链路。
final class LocalMCPServer: @unchecked Sendable {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "careloop.mcp-test-server")
    /// 工具名 → 回放的 text content 与 isError。
    private let callResponses: [String: (text: String, isError: Bool)]
    private let lock = NSLock()
    private var calls: [(name: String, argumentsJSON: String)] = []
    /// 每连接的接收缓冲（只在 listener queue 上访问）。
    private var buffers: [ObjectIdentifier: Data] = [:]

    init(callResponses: [String: (text: String, isError: Bool)] = [:]) throws {
        self.callResponses = callResponses
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    var receivedCalls: [(name: String, argumentsJSON: String)] {
        lock.lock()
        defer { lock.unlock() }
        return calls
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
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receiveLoop(on: connection)
        }
        listener.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 5)
        guard port != 0 else {
            throw NSError(domain: "MCPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "服务器未就绪"])
        }
    }

    func stop() {
        listener.cancel()
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
            buffers.removeAll()
        }
    }

    // MARK: - 接收与解析（均运行在 listener queue）

    private func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                self.buffers[ObjectIdentifier(connection), default: Data()].append(data)
                self.processBuffer(for: connection)
            }
            if error == nil && !isComplete {
                self.receiveLoop(on: connection)
            }
        }
    }

    private func processBuffer(for connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        guard var buffer = buffers[key] else { return }
        while let request = Self.takeRequest(from: &buffer) {
            respond(to: request, on: connection)
        }
        if buffer.isEmpty {
            buffers.removeValue(forKey: key)
        } else {
            buffers[key] = buffer
        }
    }

    /// 从缓冲取一个完整 HTTP 请求（头 + Content-Length 长度的体）；不足一个完整请求返回 nil。
    private static func takeRequest(from buffer: inout Data) -> (method: String, body: Data)? {
        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(data: buffer.subdata(in: 0..<headerRange.lowerBound), encoding: .utf8) ?? ""
        let lines = head.components(separatedBy: "\r\n")
        let method = lines.first?.split(separator: " ").first.map(String.init) ?? "GET"
        var contentLength = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerRange.upperBound
        let bodyEnd = bodyStart + contentLength
        guard buffer.count >= bodyEnd else { return nil }
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        buffer.removeSubrange(0..<bodyEnd)
        return (method, body)
    }

    // MARK: - 响应

    private func respond(to request: (method: String, body: Data), on connection: NWConnection) {
        // GET（SSE 流建立）按协议以 405 拒绝：本服务器只支持 POST 请求-响应。
        guard request.method == "POST" else {
            send(raw: Data("HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n".utf8), on: connection)
            return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            send(status: 400, body: Data(#"{"error":"bad json"}"#.utf8), on: connection)
            return
        }
        let method = object["method"] as? String ?? ""
        let id = object["id"]

        if method.hasPrefix("notifications/") {
            send(raw: Data("HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n".utf8), on: connection)
            return
        }

        let result: [String: Any]
        switch method {
        case "initialize":
            let params = object["params"] as? [String: Any] ?? [:]
            // 回显客户端请求的协议版本，保证协商成功。
            let version = params["protocolVersion"] as? String ?? "2025-06-18"
            result = [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "local-mcp", "version": "1.0"],
            ]
        case "tools/list":
            result = [
                "tools": [
                    ["name": "maps-around-search", "description": "周边搜索", "inputSchema": ["type": "object"]]
                ]
            ]
        case "tools/call":
            let params = object["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let argumentsJSON = (try? String(
                data: JSONSerialization.data(withJSONObject: arguments),
                encoding: .utf8
            )) ?? "{}"
            lock.lock()
            calls.append((name, argumentsJSON))
            lock.unlock()
            if let script = callResponses[name] {
                result = ["content": [["type": "text", "text": script.text]], "isError": script.isError]
            } else {
                result = ["content": [["type": "text", "text": "{\"error\":\"unknown_tool\"}"]], "isError": true]
            }
        default:
            var errorPayload: [String: Any] = [
                "jsonrpc": "2.0",
                "error": ["code": -32601, "message": "method not found"],
            ]
            if let id { errorPayload["id"] = id }
            let data = (try? JSONSerialization.data(withJSONObject: errorPayload)) ?? Data()
            send(status: 200, body: data, on: connection)
            return
        }

        var payload: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { payload["id"] = id }
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        send(status: 200, body: data, on: connection)
    }

    private func send(status: Int, body: Data, on connection: NWConnection) {
        let head = "HTTP/1.1 \(status) OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: keep-alive\r\n\r\n"
        send(raw: Data(head.utf8) + body, on: connection)
    }

    private func send(raw: Data, on connection: NWConnection) {
        connection.send(content: raw, completion: .contentProcessed { _ in })
    }
}

struct AmapMCPClientTests {
    private static let amapPOIsJSON = """
    {"status":"1","pois":[
      {"id":"B0FF01","name":"西贝莜面村（国贸店）","type":"餐饮服务;中餐厅;西北菜","address":"建国门外大街1号","location":"116.457100,39.908700","distance":"320"},
      {"id":"B0FF02","name":"庆丰包子铺（光辉里店）","type":"餐饮服务;小吃快餐;包子","address":"光辉里小区1号楼","location":"116.452900,39.912600","distance":"150"}
    ]}
    """

    private func makeClient(callResponses: [String: (text: String, isError: Bool)]) throws -> (AmapMCPClient, LocalMCPServer) {
        let server = try LocalMCPServer(callResponses: callResponses)
        try server.start()
        let client = AmapMCPClient(
            apiKey: "test-key",
            endpoint: URL(string: "http://127.0.0.1:\(server.port)/mcp")!
        )
        return (client, server)
    }

    /// initialize 握手 + tools/call 全链路：参数原样送达，text content 完整返回。
    @Test func callToolReturnsTextAndPassesArguments() async throws {
        let (client, server) = try makeClient(callResponses: [
            "maps-around-search": (Self.amapPOIsJSON, false),
        ])
        defer { server.stop() }

        let text = try await client.callTool(
            name: "maps-around-search",
            argumentsJSON: #"{"keywords":"粥","location":"116.454000,39.916500","radius":1000}"#
        )
        #expect(text.contains("西贝莜面村"))

        let calls = server.receivedCalls
        guard let call = calls.first else {
            Issue.record("服务器应收到一次 tools/call")
            return
        }
        #expect(call.name == "maps-around-search")
        #expect(call.argumentsJSON.contains("粥"))
        #expect(call.argumentsJSON.contains("116.454000,39.916500"))
    }

    /// 服务端 isError=true 时映射为 MCPCallError.serverError，且断开会话。
    @Test func serverErrorSurfaceAndReconnect() async throws {
        let (client, server) = try makeClient(callResponses: [
            "maps-around-search": ("高德配额超限", true),
        ])
        defer { server.stop() }

        do {
            _ = try await client.callTool(name: "maps-around-search", argumentsJSON: "{}")
            Issue.record("应抛出 serverError")
        } catch let error as MCPCallError {
            guard case .serverError = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }

        // 出错断开后，第二次调用应重新握手并拿到同一脚本（服务器无状态回放）。
        do {
            _ = try await client.callTool(name: "maps-around-search", argumentsJSON: "{}")
            Issue.record("第二次调用仍应报错（脚本固定 isError）")
        } catch let error as MCPCallError {
            guard case .serverError = error else {
                Issue.record("重连后的错误类型不符：\(error)")
                return
            }
        }
        #expect(server.receivedCalls.count == 2, "两次调用都应到达服务器")
    }

    /// 空 Key：isConfigured 为 false，调用直接抛 notConfigured，不触网。
    @Test func emptyKeyIsNotConfigured() async throws {
        let client = AmapMCPClient(apiKey: "  ")
        #expect(!client.isConfigured)
        do {
            _ = try await client.callTool(name: "maps-around-search", argumentsJSON: "{}")
            Issue.record("未配置时应抛 notConfigured")
        } catch let error as MCPCallError {
            guard case .notConfigured = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
    }

    /// 非法参数 JSON 映射为 invalidArguments。
    @Test func invalidArgumentsRejected() async throws {
        let (client, server) = try makeClient(callResponses: [:])
        defer { server.stop() }
        do {
            _ = try await client.callTool(name: "maps-around-search", argumentsJSON: "not-json")
            Issue.record("非法参数应抛 invalidArguments")
        } catch let error as MCPCallError {
            guard case .invalidArguments = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
    }

    /// 集成链路：本地 MCP 服务器 + AmapMCPClient + MockLocation + NearbyFoodService。
    /// 验证高德 POI 原始格式的解析与「模型视图不含经纬度」的隐私约束。
    @Test func nearbyServiceEndToEndAgainstLocalServer() async throws {
        let (client, server) = try makeClient(callResponses: [
            "maps-around-search": (Self.amapPOIsJSON, false),
        ])
        defer { server.stop() }

        let service = NearbyFoodService(
            client: client,
            location: MockLocationProvider(coordinate: LocationCoordinate(latitude: 39.9165, longitude: 116.4540))
        )
        let result = await service.search(keywords: "清淡", radiusMeters: 1200)

        #expect(result.error == nil)
        #expect(result.places.count == 2)
        #expect(result.places.first?.id == "B0FF01")
        #expect(result.places.first?.type == "中餐厅", "type 取分号段中辨识度最高的一段")
        #expect(result.places.first?.distanceMeters == 320, "distance 字符串应解析为米")

        let payload = NearbyFoodJSON.modelPayload(result)
        #expect(!payload.contains("116.4571"), "模型视图不应含经纬度")
        #expect(!payload.contains("39.9087"), "模型视图不应含经纬度")
        #expect(payload.contains("B0FF01"))

        // 定位被拒时返回机器可读错误，供模型如实解释。
        let denied = NearbyFoodService(
            client: client,
            location: MockLocationProvider(error: .unauthorized)
        )
        let deniedResult = await denied.search(keywords: nil, radiusMeters: nil)
        #expect(deniedResult.error == "location_denied")
    }
}
