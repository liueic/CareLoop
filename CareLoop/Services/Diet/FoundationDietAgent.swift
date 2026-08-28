import Foundation

#if canImport(FoundationModels)
import FoundationModels

enum FoundationDietAgentAvailability {
    @available(iOS 26.0, *)
    static var isAvailable: Bool {
        switch SystemLanguageModel.default.availability {
        case .available:
            return true
        default:
            return false
        }
    }
}

@available(iOS 26.0, *)
struct FoundationDietAgent: DietAgentSession {
    func respond(to userMessage: String, context: DietAgentContext) async throws -> DietAgentResponse {
        let safeRecipes = DietTools.filterSafeRecipes(context.recipes, profile: context.profile, dietRules: context.dietRules)
        let allowedRecipeIDs = Set(safeRecipes.map(\.id))
        let clauses = DietTools.lookupClauses(
            profile: context.profile,
            dietRules: context.dietRules,
            query: userMessage
        )
        let allowedClauseIDs = Set(clauses.map(\.id))

        let profileTool = DietProfileTool(context: context)
        let recipeTool = DietRecipeFilterTool(context: context, safeRecipes: safeRecipes)
        let clauseTool = DietClauseLookupTool(context: context)

        let session = LanguageModelSession(
            tools: [profileTool, recipeTool, clauseTool],
            instructions: {
                CloudDietAgentEngine.systemPrompt
            }
        )

        var prompt = userMessage
        if !context.history.isEmpty {
            let transcript = context.history.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
            prompt = "对话历史：\n\(transcript)\n\n用户新问题：\(userMessage)"
        }

        let response = try await session.respond(to: prompt)
        let parsed = DietTools.parseAgentJSON(response.content)
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
                usedLLM: true,
                degraded: false,
                disclaimer: CareLoopCopy.aiAdviceDisclaimer
            )
        }

        return CloudDietAgentEngine.fallbackResponse(
            safeRecipes: safeRecipes,
            clauses: clauses,
            userMessage: userMessage
        )
    }
}

@available(iOS 26.0, *)
struct DietProfileTool: Tool {
    let context: DietAgentContext

    var name: String { "get_profile_and_status" }
    var description: String { "获取脱敏用户画像、今日状态与趋势摘要" }

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        DietTools.profileAndStatusJSON(context: context)
    }
}

@available(iOS 26.0, *)
struct DietRecipeFilterTool: Tool {
    let context: DietAgentContext
    let safeRecipes: [Recipe]

    var name: String { "filter_safe_recipes" }
    var description: String { "返回已通过硬约束过滤的安全食谱" }

    @Generable
    struct Arguments {
        @Guide(description: "最多返回条数，默认12")
        var limit: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        DietTools.recipesJSON(safeRecipes, limit: arguments.limit ?? 12)
    }
}

@available(iOS 26.0, *)
struct DietClauseLookupTool: Tool {
    let context: DietAgentContext

    var name: String { "lookup_diet_clauses" }
    var description: String { "检索相关饮食指南条款" }

    @Generable
    struct Arguments {
        @Guide(description: "可选关键词")
        var query: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let clauses = DietTools.lookupClauses(
            profile: context.profile,
            dietRules: context.dietRules,
            query: arguments.query
        )
        return DietTools.clausesJSON(clauses)
    }
}

#else

enum FoundationDietAgentAvailability {
    static var isAvailable: Bool { false }
}

#endif
