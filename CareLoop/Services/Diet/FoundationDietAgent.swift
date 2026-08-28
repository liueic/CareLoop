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
@Generable
struct DietTurn {
    @Guide(description: "给用户的中文建议，简洁可执行，不做诊断、不谈调药")
    var reply: String

    @Guide(description: "必须来自工具返回的安全食谱 id")
    var citedRecipeIDs: [String]

    @Guide(description: "必须来自工具返回的指南条款 id")
    var citedClauseIDs: [String]
}

@available(iOS 26.0, *)
final class DietAgentRuntime: @unchecked Sendable {
    var context: DietAgentContext
    var safeRecipes: [Recipe]

    init(context: DietAgentContext, safeRecipes: [Recipe]) {
        self.context = context
        self.safeRecipes = safeRecipes
    }
}

@available(iOS 26.0, *)
final class FoundationDietAgent: DietAgentSession, @unchecked Sendable {
    static let systemPrompt = """
    你是慢病日常饮食助手，不是医生。必须先调用工具获取脱敏画像、安全食谱与指南条款，再给出建议。
    红线：不推荐工具列表之外的食谱；不讨论药物剂量、停药、换药；不做诊断；用药名只用于提醒咨询医生或药师，禁止判定食物与药物相互作用。
    citedRecipeIDs 与 citedClauseIDs 必须来自工具返回的 id。
    """

    private let runtime: DietAgentRuntime
    private var session: LanguageModelSession?

    init() {
        runtime = DietAgentRuntime(
            context: DietAgentContext(
                profile: ProfileTags(
                    conditions: [],
                    foodAllergies: [],
                    injuries: [],
                    doctorRestrictions: [],
                    cuisineLikes: [],
                    cuisineDislikes: [],
                    spiciness: "none",
                    dislikedIngredients: [],
                    dietGoals: [],
                    preferredSports: [],
                    avoidedSports: [],
                    facilities: [],
                    intensityCeiling: "low",
                    region: nil,
                    ageDecade: nil
                ),
                trendSummary: "",
                todayStatus: "",
                recipes: [],
                dietRules: DietGuidelineRules.load(),
                guardrailRules: GuidelineRules.load()
            ),
            safeRecipes: []
        )
    }

    func respond(to userMessage: String, context: DietAgentContext) async throws -> DietAgentResponse {
        let safeRecipes = DietTools.filterSafeRecipes(context.recipes, profile: context.profile, dietRules: context.dietRules)
        runtime.context = context
        runtime.safeRecipes = safeRecipes
        let allowedRecipeIDs = Set(safeRecipes.map(\.id))
        let allowedClauseIDs = Set(context.dietRules.clauses.map(\.id))
        let fallbackClauses = DietTools.lookupClauses(
            profile: context.profile,
            dietRules: context.dietRules,
            query: userMessage
        )

        let languageSession = ensureSession()
        do {
            let generated = try await languageSession.respond(to: userMessage, generating: DietTurn.self)
            let turn = generated.content
            if DietTools.validateAgentReply(
                text: turn.reply,
                citedRecipeIDs: turn.citedRecipeIDs,
                citedClauseIDs: turn.citedClauseIDs,
                allowedRecipeIDs: allowedRecipeIDs,
                allowedClauseIDs: allowedClauseIDs,
                guardrailRules: context.guardrailRules
            ) {
                return DietAgentResponse(
                    reply: turn.reply,
                    citedRecipeIDs: turn.citedRecipeIDs,
                    citedClauseIDs: turn.citedClauseIDs,
                    usedLLM: true,
                    degraded: false,
                    disclaimer: CareLoopCopy.aiAdviceDisclaimer
                )
            }
        } catch {
            session = nil
            do {
                let retrySession = ensureSession()
                let response = try await retrySession.respond(to: userMessage)
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
            } catch {
                session = nil
            }
        }

        return CloudDietAgentEngine.fallbackResponse(
            safeRecipes: safeRecipes,
            clauses: fallbackClauses,
            userMessage: userMessage
        )
    }

    private func ensureSession() -> LanguageModelSession {
        if let session { return session }
        let created = LanguageModelSession(
            tools: [
                DietProfileTool(runtime: runtime),
                DietRecipeFilterTool(runtime: runtime),
                DietClauseLookupTool(runtime: runtime),
            ],
            instructions: {
                Self.systemPrompt
            }
        )
        session = created
        return created
    }
}

@available(iOS 26.0, *)
struct DietProfileTool: Tool {
    let runtime: DietAgentRuntime

    var name: String { "get_profile_and_status" }
    var description: String { "获取脱敏用户画像、今日状态、饮食手帐摘要与近期血糖血压" }

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        DietTools.profileAndStatusJSON(context: runtime.context)
    }
}

@available(iOS 26.0, *)
struct DietRecipeFilterTool: Tool {
    let runtime: DietAgentRuntime

    var name: String { "filter_safe_recipes" }
    var description: String { "返回已通过硬约束过滤的安全食谱" }

    @Generable
    struct Arguments {
        @Guide(description: "最多返回条数，默认12")
        var limit: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        DietTools.recipesJSON(runtime.safeRecipes, limit: arguments.limit ?? 12)
    }
}

@available(iOS 26.0, *)
struct DietClauseLookupTool: Tool {
    let runtime: DietAgentRuntime

    var name: String { "lookup_diet_clauses" }
    var description: String { "检索相关饮食指南条款，可结合关键词与语义索引" }

    @Generable
    struct Arguments {
        @Guide(description: "可选关键词")
        var query: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let clauses = await DietTools.lookupClausesHybrid(
            profile: runtime.context.profile,
            dietRules: runtime.context.dietRules,
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
