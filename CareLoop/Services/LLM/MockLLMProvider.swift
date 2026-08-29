import Foundation

struct MockLLMProvider: LLMProviding {
    var supportsVision: Bool { true }
    var supportsToolCall: Bool { true }

    func complete(prompt: LLMPrompt) async throws -> LLMCompletion {
        // 饮食助手分支必须最先判定：其 system prompt 含「食物与药物相互作用」字样，
        // 会误中下方食物识别分支，导致工具循环最终轮永远拿不到带引用的 JSON。
        if prompt.system.contains("慢病日常饮食助手") || prompt.user.contains("citedRecipeIDs") {
            return dietAgentResponse(prompt: prompt)
        }
        if prompt.user.contains("OCR 提取的文本") || prompt.system.contains("医疗文档") {
            return medicalDocResponse()
        }
        if prompt.user.contains("饮食照片") || prompt.system.contains("食物") {
            return foodResponse()
        }
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
        let clauseIDs = prompt.user.contains("饮食") ? "[\"CL-GEN-101\"]" : "[]"
        let json = """
        {"title":"本地模板建议","body":"\(body)","citedIDs":\(jsonArray(cited)),"citedClauseIDs":\(clauseIDs)}
        """
        return LLMCompletion(text: json, modelID: "mock-template")
    }

    func completeConversation(_ request: LLMConversationRequest) async throws -> LLMConversationResponse {
        if request.tools.isEmpty {
            let completion = try await complete(
                prompt: LLMPrompt(
                    system: request.system,
                    user: request.messages.last?.content ?? "",
                    images: [],
                    maxTokens: request.maxTokens
                )
            )
            return LLMConversationResponse(
                message: LLMChatMessage(role: "assistant", content: completion.text, toolCallID: nil, toolCalls: []),
                modelID: completion.modelID,
                finishReason: "stop"
            )
        }

        let needsProfile = request.messages.last?.content?.contains("画像") == true
            || request.messages.last?.content?.contains("今晚") == true
        if needsProfile, request.messages.filter({ $0.role == "tool" }).isEmpty {
            return LLMConversationResponse(
                message: LLMChatMessage(
                    role: "assistant",
                    content: nil,
                    toolCallID: nil,
                    toolCalls: [
                        LLMToolCall(id: "call_1", name: "get_profile_and_status", argumentsJSON: "{}"),
                        LLMToolCall(id: "call_2", name: "filter_safe_recipes", argumentsJSON: "{\"limit\":8}"),
                    ]
                ),
                modelID: "mock-template",
                finishReason: "tool_calls"
            )
        }

        // 附近意图分支：先触发一次 search_nearby_food，拿到工具结果后引用 Mock POI 作答。
        let lastUserText = request.messages.last(where: { $0.role == "user" })?.content ?? ""
        let hasToolResult = request.messages.contains { $0.role == "tool" }
        let nearbyAvailable = request.tools.contains { $0.name == "search_nearby_food" }
        if nearbyAvailable, NearbyIntentDetector.isNearbyIntent(lastUserText), !hasToolResult {
            return LLMConversationResponse(
                message: LLMChatMessage(
                    role: "assistant",
                    content: nil,
                    toolCallID: nil,
                    toolCalls: [
                        LLMToolCall(id: "call_nearby", name: "search_nearby_food", argumentsJSON: "{\"keywords\":\"清淡\"}")
                    ]
                ),
                modelID: "mock-template",
                finishReason: "tool_calls"
            )
        }
        if nearbyAvailable, hasToolResult, NearbyIntentDetector.isNearbyIntent(lastUserText) {
            let json = """
            {"reply":"附近有两家不错：西贝莜面村（约320米）和庆丰包子铺（约150米）。控盐的话优先选蒸煮类主食，少喝汤底。这不是医疗建议。","citedRecipeIDs":[],"citedClauseIDs":[],"citedPOIIDs":["mock-poi-1","mock-poi-2"]}
            """
            return LLMConversationResponse(
                message: LLMChatMessage(role: "assistant", content: json, toolCallID: nil, toolCalls: []),
                modelID: "mock-template",
                finishReason: "stop"
            )
        }

        let completion = try await complete(
            prompt: LLMPrompt(
                system: request.system,
                user: request.messages.map { $0.content ?? "" }.joined(separator: "\n"),
                images: [],
                maxTokens: request.maxTokens
            )
        )
        return LLMConversationResponse(
            message: LLMChatMessage(role: "assistant", content: completion.text, toolCallID: nil, toolCalls: []),
            modelID: completion.modelID,
            finishReason: "stop"
        )
    }

    func listModels() async throws -> [String] { ["mock-template"] }

    func ping(modelID: String) async throws -> TimeInterval { 0.05 }

    /// 模拟真实 Provider 的流式节奏：工具轮先给 toolCalls；文本轮按小块吐 delta。
    func streamConversation(_ request: LLMConversationRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await completeConversation(request)
                    if !response.message.toolCalls.isEmpty {
                        // 模拟模型决定调用工具前的思考时间，让进度 UI 有稳定可观察的窗口。
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        continuation.yield(.toolCalls(response.message.toolCalls))
                        continuation.yield(.finished(response))
                    } else {
                        let text = response.message.content ?? ""
                        var offset = text.startIndex
                        while offset < text.endIndex {
                            if Task.isCancelled { break }
                            let end = text.index(offset, offsetBy: 4, limitedBy: text.endIndex) ?? text.endIndex
                            continuation.yield(.textDelta(String(text[offset..<end])))
                            offset = end
                            try await Task.sleep(nanoseconds: 60_000_000)
                        }
                        continuation.yield(.finished(response))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func dietAgentResponse(prompt: LLMPrompt) -> LLMCompletion {
        let recipeID = prompt.user.split(separator: "\n").compactMap { line -> String? in
            guard let range = line.range(of: "recipe-") else { return nil }
            let fragment = line[range.lowerBound...]
            return fragment.split(whereSeparator: { $0 == "\"" || $0 == "," || $0 == " " }).first.map(String.init)
        }.first ?? "recipe-001"
        let json = """
        {"reply":"从安全候选中推荐清淡少盐菜肴，份量适中。如有不适请咨询医生。","citedRecipeIDs":["\(recipeID)"],"citedClauseIDs":["CL-HTN-101"]}
        """
        return LLMCompletion(text: json, modelID: "mock-template")
    }

    private func foodResponse() -> LLMCompletion {
        let json = """
        {"label":"清蒸鱼+米饭","explanation":"低盐清淡，适合控压饮食"}
        """
        return LLMCompletion(text: json, modelID: "mock-template")
    }

    private func medicalDocResponse() -> LLMCompletion {
        let json = """
        {"docType":"检验报告","title":"血常规+生化","takenAt":"2026-08-20","diagnoses":["2型糖尿病","高血压2级"],"labValues":[{"name":"空腹血糖","value":"8.9","unit":"mmol/L","reference":"3.9–6.1","flag":"high"},{"name":"糖化血红蛋白","value":"7.8","unit":"%","reference":"4.0–6.0","flag":"high"},{"name":"收缩压","value":"152","unit":"mmHg","reference":"<140","flag":"high"},{"name":"血钾","value":"3.6","unit":"mmol/L","reference":"3.5–5.5","flag":null}],"medications":[{"name":"二甲双胍","dose":"500mg","frequency":"每日2次","timesOfDay":["08:00","18:00"],"frequencyPerDay":2,"cautions":"随餐服用","spec":"0.5g×20片","quantity":"1盒","durationText":"30天"},{"name":"氨氯地平","dose":"5mg","frequency":"每日1次","timesOfDay":["08:00"],"frequencyPerDay":1,"cautions":"晨起","spec":"5mg×28片","quantity":"1盒","durationText":null}],"recommendations":["两周后复查空腹血糖","低盐低脂饮食","每日监测血压"],"followUpHint":"两周后内分泌科复诊","followUpDate":"2026-09-03","followUpDepartment":"内分泌科","summary":"血糖控制欠佳，血压偏高，建议调整用药并加强监测","hospitalName":"市第一人民医院","doctorName":"王医生"}
        """
        return LLMCompletion(text: json, modelID: "mock-template")
    }

    private func jsonArray(_ ids: [String]) -> String {
        let inner = ids.map { "\"\($0)\"" }.joined(separator: ",")
        return "[\(inner)]"
    }
}
