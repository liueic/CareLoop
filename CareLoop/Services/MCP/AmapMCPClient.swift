import Foundation
import MCP

/// 高德服务的 Key 与 Keychain 约定。
enum AmapServiceConfig {
    static let keychainKey = "careloop.amap"
    static let keychainService = "CareLoop.Map"
    static let defaultEndpoint = URL(string: "https://mcp.amap.com/mcp")!

    /// 随包内置的默认 Key（构建时由 AMAP_MCP_KEY 注入，可为空）。
    static var bundledKey: String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "AmapDefaultKey") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 构建设置未定义时会残留字面量 $(AMAP_MCP_KEY)，视为未配置。
        return raw.hasPrefix("$(") ? "" : raw
    }
}

/// 高德官方 MCP Server（Streamable HTTP 端点 mcp.amap.com/mcp）客户端。
/// Key 拼在 endpoint URL 上：不落日志、不进请求体；会话懒建立，出错即断开待重建。
actor AmapMCPClient: MCPRemoteToolProviding {
    private let apiKey: String
    private let endpoint: URL
    private var client: Client?

    init(apiKey: String, endpoint: URL? = nil) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = trimmed
        let encodedKey = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? trimmed
        var components = URLComponents(url: endpoint ?? AmapServiceConfig.defaultEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: encodedKey)]
        self.endpoint = components.url ?? AmapServiceConfig.defaultEndpoint
    }

    nonisolated var isConfigured: Bool { !apiKey.isEmpty }

    func callTool(name: String, argumentsJSON: String) async throws -> String {
        guard isConfigured else { throw MCPCallError.notConfigured }
        let arguments = try Self.parseArguments(argumentsJSON)
        let client = try await ensureConnected()
        do {
            let (content, isError) = try await Self.withTimeout(seconds: 15) {
                try await client.callTool(name: name, arguments: arguments)
            }
            let text = Self.joinedText(content)
            if isError == true {
                throw MCPCallError.serverError(String(text.prefix(200)))
            }
            return text
        } catch {
            // 会话状态不可信（超时/传输错误都可能是半开连接），断开待下次重建。
            await resetConnection()
            throw Self.map(error)
        }
    }

    private func ensureConnected() async throws -> Client {
        if let client { return client }
        let client = Client(name: "CareLoop", version: "0.1")
        do {
            try await Self.withTimeout(seconds: 12) {
                try await client.connect(
                    transport: HTTPClientTransport(endpoint: self.endpoint)
                )
            }
        } catch {
            throw MCPCallError.transport("无法连接高德 MCP 服务（\(Self.shortDescription(error))）")
        }
        self.client = client
        return client
    }

    private func resetConnection() async {
        await client?.disconnect()
        client = nil
    }

    // MARK: - 转换

    private static func joinedText(_ content: [Tool.Content]) -> String {
        content.compactMap { item -> String? in
            if case .text(let text, _, _) = item { return text }
            return nil
        }
        .joined(separator: "\n")
    }

    /// OpenAI 风格 JSON 对象字符串 → MCP Value 参数字典。
    private static func parseArguments(_ json: String) throws -> [String: Value] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || trimmed == "{}" else {
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCPCallError.invalidArguments
            }
            return object.mapValues(value(from:))
        }
        return [:]
    }

    private static func value(from any: Any) -> Value {
        switch any {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            if let int = number as? Int {
                return .int(int)
            }
            return .double(number.doubleValue)
        case let array as [Any]:
            return .array(array.map(value(from:)))
        case let object as [String: Any]:
            return .object(object.mapValues(value(from:)))
        default:
            return .null
        }
    }

    private static func map(_ error: Error) -> MCPCallError {
        if let callError = error as? MCPCallError { return callError }
        if error is CancellationError {
            return .transport("请求超时或被取消")
        }
        return .transport(shortDescription(error))
    }

    private static func shortDescription(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return String(describing: type(of: error))
    }

    /// 任务组竞速超时：超时抛 MCPCallError.transport。
    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw MCPCallError.transport("请求超时（\(Int(seconds))s）")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw MCPCallError.transport("请求未返回")
            }
            return result
        }
    }
}
