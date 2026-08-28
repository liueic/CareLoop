import Foundation
@testable import CareLoop
import Testing

struct DietToolsPipelineTests {
    private var heartProfile: ProfileTags {
        ProfileTags(
            conditions: ["心脏病", "高血压"],
            foodAllergies: ["虾"],
            injuries: [],
            doctorRestrictions: [],
            cuisineLikes: ["粤菜"],
            cuisineDislikes: [],
            spiciness: "none",
            dislikedIngredients: ["香菜"],
            dietGoals: ["控盐"],
            preferredSports: ["快走"],
            avoidedSports: ["HIIT"],
            facilities: ["室内", "户外"],
            intensityCeiling: "低",
            region: "广东",
            ageDecade: "60s"
        )
    }

    @Test func hardFilterDropsAllergenAndHighSalt() {
        let recipes = [
            Recipe(id: "safe", name: "清蒸鲈鱼", cuisine: "粤菜", spiciness: "none", tags: ["低盐"], ingredients: ["鲈鱼"], avoidFor: [], suitableFor: ["高血压"], mealType: ["午餐"], cookingNote: ""),
            Recipe(id: "salt", name: "腊味煲仔饭", cuisine: "粤菜", spiciness: "none", tags: ["高盐", "腌制"], ingredients: ["腊肉"], avoidFor: [], suitableFor: [], mealType: ["午餐"], cookingNote: ""),
            Recipe(id: "allergen", name: "白灼虾", cuisine: "粤菜", spiciness: "none", tags: ["低盐"], ingredients: ["虾"], avoidFor: [], suitableFor: [], mealType: ["午餐"], cookingNote: ""),
        ]
        let filtered = DietTools.filterSafeRecipes(recipes, profile: heartProfile, dietRules: DietGuidelineRules.load())
        #expect(filtered.map(\.id) == ["safe"])
    }

    @Test func clauseLookupPrefersConditionTags() {
        let rules = DietGuidelineCompiler.mergedWithClinicalAdvice(DietGuidelineRules.load())
        let clauses = DietTools.lookupClauses(profile: heartProfile, dietRules: rules, query: "少盐", limit: 5)
        #expect(!clauses.isEmpty)
        #expect(clauses.contains { $0.tags.contains("高血压") || $0.tags.contains("控盐") })
    }

    @Test func mergeClausesPutsTaggedFirstThenSpotlight() {
        let tagged = [
            DietClause(id: "CL-A", title: "A", body: "a", tags: ["高血压"], source: "t"),
        ]
        let extra = DietClause(id: "CL-B", title: "B", body: "b", tags: ["糖尿病"], source: "t")
        let merged = DietTools.mergeClauses(
            tagged: tagged,
            spotlightIDs: ["CL-B", "CL-A", "CL-MISSING"],
            allClauses: tagged + [extra],
            limit: 5
        )
        #expect(merged.map(\.id) == ["CL-A", "CL-B"])
    }

    @Test func validateRejectsUnknownRecipeAndBlacklist() {
        let rules = GuidelineRules.load()
        #expect(
            DietTools.validateAgentReply(
                text: "建议停药",
                citedRecipeIDs: ["recipe-001"],
                citedClauseIDs: [],
                allowedRecipeIDs: ["recipe-001"],
                allowedClauseIDs: ["CL-GEN-101"],
                guardrailRules: rules
            ) == false
        )
        #expect(
            DietTools.validateAgentReply(
                text: "清淡饮食",
                citedRecipeIDs: ["x"],
                citedClauseIDs: ["CL-GEN-101"],
                allowedRecipeIDs: ["recipe-001"],
                allowedClauseIDs: ["CL-GEN-101"],
                guardrailRules: rules
            ) == false
        )
        #expect(
            DietTools.validateAgentReply(
                text: "清淡饮食",
                citedRecipeIDs: ["recipe-001"],
                citedClauseIDs: ["CL-GEN-101"],
                allowedRecipeIDs: ["recipe-001"],
                allowedClauseIDs: ["CL-GEN-101"],
                guardrailRules: rules
            )
        )
    }

    @Test func profileJSONIncludesDietLogGlucoseAndMedicationGuard() {
        let context = DietAgentContext(
            profile: heartProfile,
            trendSummary: "睡眠 z=-1.2",
            todayStatus: "稳定",
            recipes: [],
            dietRules: DietGuidelineRules.load(),
            guardrailRules: GuidelineRules.load(),
            recentDietLogSummary: "晚饭清蒸鱼",
            recentGlucose: "血糖 7.4 mmol/L（来源：Mock）",
            recentBloodPressure: "血压 138/88 mmHg（来源：Mock）",
            currentMedicationNames: ["氨氯地平"]
        )
        let json = DietTools.profileAndStatusJSON(context: context)
        #expect(json.contains("清蒸鱼"))
        #expect(json.contains("7.4"))
        #expect(json.contains("138"))
        #expect(json.contains("氨氯地平"))
        #expect(json.contains("禁止据此判断食物与药物相互作用"))
    }

    @Test func dietLogSummarySkipsPendingAI() {
        let confirmed = DailyLogEntry(
            kind: .text,
            contentText: "午饭时蔬豆腐",
            tags: [LogTag.diet.rawValue],
            confirmation: .confirmed
        )
        let pending = DailyLogEntry(
            kind: .text,
            contentText: "疑似奶茶",
            tags: [LogTag.diet.rawValue],
            confirmation: .pendingAI
        )
        let summary = DietTools.dietLogSummary(entries: [confirmed, pending])
        #expect(summary.contains("时蔬豆腐"))
        #expect(!summary.contains("奶茶"))
    }

    @Test func spotlightIdentifierParsing() {
        #expect(DietSpotlightIndexer.clauseID(from: "clause:CL-HTN-101") == "CL-HTN-101")
        #expect(DietSpotlightIndexer.clauseID(from: "recipe:recipe-001") == nil)
    }
}

struct DietGuidelineCompilerTests {
    @Test func mergesDietRelatedClinicalAdvice() throws {
        let fixture = """
        {
          "advice": [
            {
              "id": "AD-LIP-101",
              "disease_category": "dyslipidemia",
              "title_cn": "饮食调整",
              "text_cn": "建议减少饱和脂肪和反式脂肪摄入，增加不饱和脂肪酸。"
            },
            {
              "id": "AD-SLP-101",
              "disease_category": "sleep",
              "title_cn": "睡眠改善",
              "text_cn": "建议保持规律作息，每晚睡眠7-9小时。"
            }
          ]
        }
        """.data(using: .utf8)!
        let bundled = DietGuidelineRules(
            version: "test",
            disclaimer: "d",
            constraints: [],
            clauses: [
                DietClause(id: "CL-GEN-101", title: "通用", body: "仅供参考", tags: ["通用"], source: "t"),
            ]
        )
        let merged = DietGuidelineCompiler.mergedWithClinicalAdvice(bundled, adviceData: fixture)
        #expect(merged.clauses.contains { $0.id == "CL-AD-LIP-101" })
        #expect(!merged.clauses.contains { $0.id == "CL-AD-SLP-101" })
        #expect(DietGuidelineCompiler.isDietRelated(title: "饮食调整", body: "减少饱和脂肪"))
        #expect(!DietGuidelineCompiler.isDietRelated(title: "睡眠改善", body: "规律作息"))
    }
}

struct DietAgentSessionTests {
    @Test func mockAgentReturnsConfiguredReply() async throws {
        let agent = MockDietAgent(
            response: DietAgentResponse(
                reply: "今晚清蒸鲈鱼",
                citedRecipeIDs: ["recipe-001"],
                citedClauseIDs: ["CL-HTN-101"],
                usedLLM: false,
                degraded: false,
                disclaimer: CareLoopCopy.aiAdviceDisclaimer
            )
        )
        let reply = try await agent.respond(
            to: "今晚吃什么",
            context: DietAgentContext(
                profile: ProfileTags(
                    conditions: ["高血压"],
                    foodAllergies: [],
                    injuries: [],
                    doctorRestrictions: [],
                    cuisineLikes: [],
                    cuisineDislikes: [],
                    spiciness: "none",
                    dislikedIngredients: [],
                    dietGoals: ["控盐"],
                    preferredSports: [],
                    avoidedSports: [],
                    facilities: [],
                    intensityCeiling: "低",
                    region: nil,
                    ageDecade: nil
                ),
                trendSummary: "",
                todayStatus: "稳定",
                recipes: ContentLibrary.loadRecipes(),
                dietRules: DietGuidelineRules.load(),
                guardrailRules: GuidelineRules.load()
            )
        )
        #expect(reply.reply.contains("清蒸鲈鱼"))
        #expect(agent.lastMessage == "今晚吃什么")
        #expect(reply.citedClauseIDs == ["CL-HTN-101"])
    }

    @Test func cloudFallbackUsesSafeRecipes() async throws {
        let recipes = [
            Recipe(id: "recipe-001", name: "清蒸鲈鱼", cuisine: "粤菜", spiciness: "none", tags: ["低盐"], ingredients: ["鲈鱼"], avoidFor: [], suitableFor: ["高血压"], mealType: ["晚餐"], cookingNote: ""),
        ]
        let fallback = CloudDietAgentEngine.fallbackResponse(
            safeRecipes: recipes,
            clauses: [
                DietClause(id: "CL-HTN-101", title: "减少钠盐摄入", body: "每日<5g", tags: ["高血压"], source: "t"),
            ],
            userMessage: "今晚吃什么"
        )
        #expect(fallback.degraded)
        #expect(fallback.citedRecipeIDs == ["recipe-001"])
        #expect(fallback.reply.contains("清蒸鲈鱼"))
    }

    @Test func foodCatalogLoadsIfPresent() {
        let catalog = ContentLibrary.loadFoodCatalog()
        if !catalog.isEmpty {
            #expect(catalog.contains { !$0.shortDesc.isEmpty || !$0.longDesc.isEmpty })
        }
    }
}

final class MockDietAgent: DietAgentSession, @unchecked Sendable {
    var response: DietAgentResponse
    var lastMessage: String?

    init(response: DietAgentResponse) {
        self.response = response
    }

    func respond(to userMessage: String, context: DietAgentContext) async throws -> DietAgentResponse {
        lastMessage = userMessage
        return response
    }
}
