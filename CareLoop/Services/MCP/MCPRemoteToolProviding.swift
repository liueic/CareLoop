import Foundation

/// 远程 MCP Server 的最小桥接协议。
/// Agent 工具循环只认识字符串进出：LLMToolCall.argumentsJSON → callTool → 文本结果回填。
/// 未来接入新的 MCP Server（天气、点评等）只需实现该协议。
protocol MCPRemoteToolProviding: Sendable {
    /// Key 是否已配置（决定是否把远程工具注入 Agent）。
    var isConfigured: Bool { get }
    /// 调用远程工具；argumentsJSON 为 OpenAI 风格的 JSON 对象字符串。
    /// - Returns: 工具返回的文本内容（多个 text content 拼接）。
    /// - Throws: 网络 / 超时 / 协议错误。
    func callTool(name: String, argumentsJSON: String) async throws -> String
}

enum MCPCallError: Error, LocalizedError, Sendable {
    case notConfigured
    case invalidArguments
    case serverError(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "未配置 MCP 服务"
        case .invalidArguments: "工具参数不是合法 JSON 对象"
        case .serverError(let message): "MCP 服务返回错误：\(message)"
        case .transport(let message): message
        }
    }
}
