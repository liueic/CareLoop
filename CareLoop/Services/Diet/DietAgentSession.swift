import Foundation

/// 饱饱回复过程中的可观测事件：工具调用进度、流式文本增量、最终结果。
enum DietAgentEvent: Sendable {
    case toolStarted(name: String, label: String)
    case toolFinished(name: String)
    case replyDelta(String)
    case finished(DietAgentResponse)
}

protocol DietAgentSession: Sendable {
    func respond(to userMessage: String, context: DietAgentContext) async throws -> DietAgentResponse
    func streamRespond(to userMessage: String, context: DietAgentContext) -> AsyncThrowingStream<DietAgentEvent, Error>
}

extension DietAgentSession {
    /// 默认实现：不支持流式的会话一次性给出最终结果。
    func streamRespond(to userMessage: String, context: DietAgentContext) -> AsyncThrowingStream<DietAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await respond(to: userMessage, context: context)
                    continuation.yield(.finished(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum DietAgentFactory {
    static func make(
        llm: any LLMProviding,
        nearby: (any NearbyFoodSearching)? = nil,
        preferOnDevice: Bool = true
    ) -> any DietAgentSession {
        // UI 测试用它强制走云端 Agent + Mock Provider，保证行为确定。
        let forceCloud = ProcessInfo.processInfo.environment["CARELOOP_FORCE_CLOUD_AGENT"] == "1"
        #if canImport(FoundationModels)
        if preferOnDevice && !forceCloud, #available(iOS 26.0, *) {
            if FoundationDietAgentAvailability.isAvailable {
                return FoundationDietAgent()
            }
        }
        #endif
        return CloudDietAgent(llm: llm, nearby: nearby)
    }
}

/// 工具名到用户可见中文标签的映射（进度 UI 用）。
enum DietToolPresentation {
    static func label(for name: String) -> String {
        switch name {
        case "get_profile_and_status": return "查看健康档案"
        case "filter_safe_recipes": return "筛选安全食谱"
        case "lookup_diet_clauses": return "检索饮食指南"
        case "search_nearby_food": return "搜索附近餐厅"
        default: return "查询资料"
        }
    }
}

enum CloudDietAgentEngine {
    static let systemPrompt = """
    你是慢病日常饮食助手，不是医生。你只能基于工具返回的安全食谱与指南条款回答。
    红线：不推荐工具列表之外的食谱；不讨论药物剂量、停药、换药；不做诊断；用药名只用于提醒咨询医生或药师，禁止判定食物与药物相互作用。
    回答请简洁、可执行，并在 JSON 中给出 citedRecipeIDs 与 citedClauseIDs（如有引用）。
    """

    /// 附近餐厅工具可用时追加到 system prompt 的边界条款。
    static let nearbyPromptAddendum = """
    附近餐厅：当用户想了解附近、周边吃什么时，调用 search_nearby_food 获取真实餐厅列表。餐厅列表是位置参考信息，不是安全食谱候选集；健康评价仍以指南条款与安全食谱为准。
    工具返回 error 时如实告知用户原因并给出替代建议（如换关键词、稍后再试），禁止编造餐厅。
    回复 JSON 的 citedPOIIDs 只能填 search_nearby_food 返回的 place id；citedRecipeIDs 与 citedPOIIDs 至少引用其一。
    """

    static func respond(
        to userMessage: String,
        context: DietAgentContext,
        llm: any LLMProviding,
        nearby: (any NearbyFoodSearching)? = nil
    ) async throws -> DietAgentResponse {
        var result: DietAgentResponse?
        for try await event in stream(to: userMessage, context: context, llm: llm, nearby: nearby) {
            if case .finished(let response) = event {
                result = response
            }
        }
        return result ?? fallbackResponse(
            safeRecipes: DietTools.filterSafeRecipes(context.recipes, profile: context.profile, dietRules: context.dietRules),
            clauses: [],
            userMessage: userMessage
        )
    }

    static func stream(
        to userMessage: String,
        context: DietAgentContext,
        llm: any LLMProviding,
        nearby: (any NearbyFoodSearching)? = nil
    ) -> AsyncThrowingStream<DietAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let safeRecipes = DietTools.filterSafeRecipes(context.recipes, profile: context.profile, dietRules: context.dietRules)
                let allowedRecipeIDs = Set(safeRecipes.map(\.id))
                let allowedClauseIDs = Set(context.dietRules.clauses.map(\.id))
                // 附近工具仅在服务已配置且 Provider 支持 tool call 时注入。
                let nearbyEnabled = (nearby?.isConfigured ?? false) && llm.supportsToolCall
                let system = nearbyEnabled ? systemPrompt + "\n" + nearbyPromptAddendum : systemPrompt
                let tools = dietToolDefinitions(includeNearby: nearbyEnabled)
                var seenPlaces: [NearbyPlace] = []

                var messages: [LLMChatMessage] = context.history.map { item in
                    LLMChatMessage(role: item.role, content: item.content, toolCallID: nil, toolCalls: [])
                }
                messages.append(LLMChatMessage(role: "user", content: userMessage, toolCallID: nil, toolCalls: []))

                var extractor = StreamingReplyExtractor()

                do {
                    loop: for _ in 0..<6 {
                        // 每轮重置抽取器：工具轮里模型可能先吐几个字，随后真正答案才在下一轮开始。
                        extractor = StreamingReplyExtractor()
                        var roundResponse: LLMConversationResponse?
                        for try await event in llm.streamConversation(
                            LLMConversationRequest(
                                system: system,
                                messages: messages,
                                tools: tools,
                                maxTokens: 700
                            )
                        ) {
                            switch event {
                            case .textDelta(let delta):
                                let visible = extractor.feed(delta)
                                if !visible.isEmpty {
                                    continuation.yield(.replyDelta(visible))
                                }
                            case .toolCalls:
                                continue
                            case .finished(let response):
                                roundResponse = response
                            }
                        }
                        guard let response = roundResponse else { break loop }
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        let assistant = response.message

                        if !assistant.toolCalls.isEmpty {
                            messages.append(assistant)
                            for call in assistant.toolCalls {
                                continuation.yield(
                                    .toolStarted(name: call.name, label: DietToolPresentation.label(for: call.name))
                                )
                                let outcome = await executeTool(
                                    call: call,
                                    context: context,
                                    safeRecipes: safeRecipes,
                                    nearby: nearby
                                )
                                seenPlaces.append(contentsOf: outcome.places)
                                continuation.yield(.toolFinished(name: call.name))
                                messages.append(
                                    LLMChatMessage(
                                        role: "tool",
                                        content: outcome.content,
                                        toolCallID: call.id,
                                        toolCalls: []
                                    )
                                )
                            }
                            continue loop
                        }

                        guard let content = assistant.content, !content.isEmpty else { break loop }
                        let parsed = DietTools.parseAgentJSON(content)
                        let placeByID = Dictionary(uniqueKeysWithValues: seenPlaces.map { ($0.id, $0) })
                        let allowedPOIIDs = Set(placeByID.keys)
                        let citedPOIs = parsed.poiIDs.compactMap { placeByID[$0] }
                        if DietTools.validateAgentReply(
                            text: parsed.reply,
                            citedRecipeIDs: parsed.recipeIDs,
                            citedClauseIDs: parsed.clauseIDs,
                            allowedRecipeIDs: allowedRecipeIDs,
                            allowedClauseIDs: allowedClauseIDs,
                            guardrailRules: context.guardrailRules,
                            citedPOIIDs: parsed.poiIDs,
                            allowedPOIIDs: allowedPOIIDs
                        ) {
                            continuation.yield(
                                .finished(
                                    DietAgentResponse(
                                        reply: parsed.reply,
                                        citedRecipeIDs: parsed.recipeIDs,
                                        citedClauseIDs: parsed.clauseIDs,
                                        citedPOIs: Array(citedPOIs.prefix(4)),
                                        usedLLM: true,
                                        degraded: false,
                                        disclaimer: CareLoopCopy.aiAdviceDisclaimer
                                    )
                                )
                            )
                            continuation.finish()
                            return
                        }
                        break loop
                    }

                    // 任务被取消时静默收尾：不吐降级结果，让 UI 保留已流出的部分文本。
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    // 降级才需要种子条款，此时再查——Spotlight 首查可能很慢，
                    // 不应让它阻塞正常回答路径的首字节。
                    let fallbackClauses = await DietTools.lookupClausesHybrid(
                        profile: context.profile,
                        dietRules: context.dietRules,
                        query: userMessage
                    )
                    continuation.yield(
                        .finished(
                            fallbackResponse(
                                safeRecipes: safeRecipes,
                                clauses: fallbackClauses,
                                userMessage: userMessage
                            )
                        )
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func dietToolDefinitions(includeNearby: Bool = false) -> [LLMToolDefinition] {
        var tools: [LLMToolDefinition] = [
            LLMToolDefinition(
                name: "get_profile_and_status",
                description: "获取脱敏用户画像、今日状态、饮食手帐摘要与近期血糖血压",
                parametersJSON: """
                {"type":"object","properties":{}}
                """
            ),
            LLMToolDefinition(
                name: "filter_safe_recipes",
                description: "按病种、过敏、忌口与饮食指南硬约束过滤后的安全食谱列表",
                parametersJSON: """
                {"type":"object","properties":{"limit":{"type":"integer","description":"最多返回条数，默认12"}}}
                """
            ),
            LLMToolDefinition(
                name: "lookup_diet_clauses",
                description: "检索与画像或用户问题相关的饮食指南条款",
                parametersJSON: """
                {"type":"object","properties":{"query":{"type":"string","description":"可选关键词"}}}
                """
            ),
        ]
        if includeNearby {
            tools.append(
                LLMToolDefinition(
                    name: "search_nearby_food",
                    description: "搜索当前位置附近的餐厅（高德周边搜索），返回名称/菜系/地址/距离。仅当用户想了解附近、周边吃什么时调用",
                    parametersJSON: """
                    {"type":"object","properties":{"keywords":{"type":"string","description":"搜索关键词，可结合健康需求，如 清淡 轻食 粥 素食"},"radius_meters":{"type":"integer","description":"搜索半径（米），100-5000，默认1500"}}}
                    """
                )
            )
        }
        return tools
    }

    private struct ToolOutcome {
        var content: String
        var places: [NearbyPlace] = []
    }

    private static func executeTool(
        call: LLMToolCall,
        context: DietAgentContext,
        safeRecipes: [Recipe],
        nearby: (any NearbyFoodSearching)?
    ) async -> ToolOutcome {
        switch call.name {
        case "get_profile_and_status":
            return ToolOutcome(content: DietTools.profileAndStatusJSON(context: context))
        case "filter_safe_recipes":
            let args = LLMJSON.object(from: call.argumentsJSON) ?? [:]
            let limit = args["limit"] as? Int ?? 12
            return ToolOutcome(content: DietTools.recipesJSON(safeRecipes, limit: max(1, min(limit, 20))))
        case "lookup_diet_clauses":
            let args = LLMJSON.object(from: call.argumentsJSON) ?? [:]
            let query = args["query"] as? String ?? ""
            let clauses = await DietTools.lookupClausesHybrid(
                profile: context.profile,
                dietRules: context.dietRules,
                query: query.isEmpty ? nil : query
            )
            return ToolOutcome(content: DietTools.clausesJSON(clauses))
        case "search_nearby_food":
            guard let nearby, nearby.isConfigured else {
                return ToolOutcome(content: "{\"error\":\"tool_unavailable\"}")
            }
            let args = LLMJSON.object(from: call.argumentsJSON) ?? [:]
            let keywords = args["keywords"] as? String
            let radius = args["radius_meters"] as? Int ?? args["radius"] as? Int
            let result = await nearby.search(keywords: keywords, radiusMeters: radius)
            return ToolOutcome(content: NearbyFoodJSON.modelPayload(result), places: result.places)
        default:
            return ToolOutcome(content: "{\"error\":\"unknown_tool\"}")
        }
    }

    static func fallbackResponse(
        safeRecipes: [Recipe],
        clauses: [DietClause],
        userMessage: String
    ) -> DietAgentResponse {
        let picks = Array(safeRecipes.prefix(2))
        let names = picks.map(\.name).joined(separator: "、")
        let clauseHint = clauses.first.map { "参考：\($0.title)。" } ?? ""
        let reply: String
        if picks.isEmpty {
            reply = "当前没有通过安全过滤的食谱候选。建议保持清淡少盐饮食，并咨询医生或营养师。\(clauseHint)"
        } else {
            reply = "从安全候选中可考虑：\(names)。烹调少盐少糖，份量适中。\(clauseHint) 如需调整用药相关饮食，请咨询医生。"
        }
        return DietAgentResponse(
            reply: reply,
            citedRecipeIDs: picks.map(\.id),
            citedClauseIDs: Array(clauses.prefix(1).map(\.id)),
            usedLLM: false,
            degraded: true,
            disclaimer: CareLoopCopy.aiAdviceDisclaimer
        )
    }
}

final class CloudDietAgent: DietAgentSession, @unchecked Sendable {
    let llm: any LLMProviding
    let nearby: (any NearbyFoodSearching)?

    init(llm: any LLMProviding, nearby: (any NearbyFoodSearching)? = nil) {
        self.llm = llm
        self.nearby = nearby
    }

    func respond(to userMessage: String, context: DietAgentContext) async throws -> DietAgentResponse {
        try await CloudDietAgentEngine.respond(to: userMessage, context: context, llm: llm, nearby: nearby)
    }

    func streamRespond(to userMessage: String, context: DietAgentContext) -> AsyncThrowingStream<DietAgentEvent, Error> {
        CloudDietAgentEngine.stream(to: userMessage, context: context, llm: llm, nearby: nearby)
    }
}
