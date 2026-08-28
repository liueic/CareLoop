import Foundation

protocol DietAgentSession: Sendable {
    func respond(to userMessage: String, context: DietAgentContext) async throws -> DietAgentResponse
}

enum DietAgentFactory {
    static func make(
        llm: any LLMProviding,
        preferOnDevice: Bool = true
    ) -> any DietAgentSession {
        #if canImport(FoundationModels)
        if preferOnDevice, #available(iOS 26.0, *) {
            if FoundationDietAgentAvailability.isAvailable {
                return FoundationDietAgent()
            }
        }
        #endif
        return CloudDietAgent(llm: llm)
    }
}

enum CloudDietAgentEngine {
    static let systemPrompt = """
    你是慢病日常饮食助手，不是医生。你只能基于工具返回的安全食谱与指南条款回答。
    红线：不推荐工具列表之外的食谱；不讨论药物剂量、停药、换药；不做诊断；用药名只用于提醒咨询医生或药师，禁止判定食物与药物相互作用。
    回答请简洁、可执行，并在 JSON 中给出 citedRecipeIDs 与 citedClauseIDs（如有引用）。
    """

    static func respond(
        to userMessage: String,
        context: DietAgentContext,
        llm: any LLMProviding
    ) async throws -> DietAgentResponse {
        let safeRecipes = DietTools.filterSafeRecipes(context.recipes, profile: context.profile, dietRules: context.dietRules)
        let allowedRecipeIDs = Set(safeRecipes.map(\.id))
        let allowedClauseIDs = Set(context.dietRules.clauses.map(\.id))
        let seededClauses = await DietTools.lookupClausesHybrid(
            profile: context.profile,
            dietRules: context.dietRules,
            query: userMessage
        )

        var messages: [LLMChatMessage] = context.history.map { item in
            LLMChatMessage(role: item.role, content: item.content, toolCallID: nil, toolCalls: [])
        }
        messages.append(LLMChatMessage(role: "user", content: userMessage, toolCallID: nil, toolCalls: []))

        let tools = dietToolDefinitions()
        var usedLLM = false

        for _ in 0..<6 {
            let response = try await llm.completeConversation(
                LLMConversationRequest(
                    system: Self.systemPrompt,
                    messages: messages,
                    tools: tools,
                    maxTokens: 700
                )
            )
            usedLLM = true
            let assistant = response.message

            if !assistant.toolCalls.isEmpty {
                messages.append(assistant)
                for call in assistant.toolCalls {
                    let output = await executeTool(
                        call: call,
                        context: context,
                        safeRecipes: safeRecipes
                    )
                    messages.append(
                        LLMChatMessage(
                            role: "tool",
                            content: output,
                            toolCallID: call.id,
                            toolCalls: []
                        )
                    )
                }
                continue
            }

            guard let content = assistant.content, !content.isEmpty else { break }
            let parsed = DietTools.parseAgentJSON(content)
            if DietTools.validateAgentReply(
                text: parsed.reply,
                citedRecipeIDs: parsed.recipeIDs,
                citedClauseIDs: parsed.clauseIDs,
                allowedRecipeIDs: allowedRecipeIDs,
                allowedClauseIDs: allowedClauseIDs,
                guardrailRules: context.guardrailRules
            ) {
                return DietAgentResponse(
                    reply: parsed.reply,
                    citedRecipeIDs: parsed.recipeIDs,
                    citedClauseIDs: parsed.clauseIDs,
                    usedLLM: usedLLM,
                    degraded: false,
                    disclaimer: CareLoopCopy.aiAdviceDisclaimer
                )
            }
            break
        }

        return fallbackResponse(
            safeRecipes: safeRecipes,
            clauses: seededClauses,
            userMessage: userMessage
        )
    }

    private static func dietToolDefinitions() -> [LLMToolDefinition] {
        [
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
    }

    private static func executeTool(
        call: LLMToolCall,
        context: DietAgentContext,
        safeRecipes: [Recipe]
    ) async -> String {
        switch call.name {
        case "get_profile_and_status":
            return DietTools.profileAndStatusJSON(context: context)
        case "filter_safe_recipes":
            let args = LLMJSON.object(from: call.argumentsJSON) ?? [:]
            let limit = args["limit"] as? Int ?? 12
            return DietTools.recipesJSON(safeRecipes, limit: max(1, min(limit, 20)))
        case "lookup_diet_clauses":
            let args = LLMJSON.object(from: call.argumentsJSON) ?? [:]
            let query = args["query"] as? String ?? ""
            let clauses = await DietTools.lookupClausesHybrid(
                profile: context.profile,
                dietRules: context.dietRules,
                query: query.isEmpty ? nil : query
            )
            return DietTools.clausesJSON(clauses)
        default:
            return "{\"error\":\"unknown_tool\"}"
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

    init(llm: any LLMProviding) {
        self.llm = llm
    }

    func respond(to userMessage: String, context: DietAgentContext) async throws -> DietAgentResponse {
        try await CloudDietAgentEngine.respond(to: userMessage, context: context, llm: llm)
    }
}
