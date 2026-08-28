import Foundation

struct MockLLMProvider: LLMProviding {
    var supportsVision: Bool { false }

    func complete(prompt: LLMPrompt) async throws -> LLMCompletion {
        let ids = prompt.user
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- ") else { return nil }
                let rest = trimmed.dropFirst(2)
                return rest.split(separator: " ").first.map(String.init)
            }
        let cited = Array(ids.prefix(2))
        let names = cited.joined(separator: "、")
        let body: String
        if prompt.user.contains("饮食") {
            body = "建议从候选中选择 \(names)。烹调少盐少糖，口味按你的辣度偏好来。这不是医疗建议。"
        } else {
            body = "建议从候选中选择 \(names)，保持能够对话的强度。出现胸痛或严重不适请停止并就医。"
        }
        let json = """
        {"title":"本地模板建议","body":"\(body)","citedIDs":\(jsonArray(cited))}
        """
        return LLMCompletion(text: json, modelID: "mock-template")
    }

    func listModels() async throws -> [String] { ["mock-template"] }

    func ping(modelID: String) async throws -> TimeInterval { 0.05 }

    private func jsonArray(_ ids: [String]) -> String {
        let inner = ids.map { "\"\($0)\"" }.joined(separator: ",")
        return "[\(inner)]"
    }
}
