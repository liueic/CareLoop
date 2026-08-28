import Foundation
@testable import CareLoop
import Testing

struct DietGuidelineStoreTests {
    private var hypertensiveProfile: ProfileTags {
        ProfileTags(
            conditions: ["高血压", "糖尿病"],
            foodAllergies: [],
            injuries: [],
            doctorRestrictions: [],
            cuisineLikes: ["粤菜"],
            cuisineDislikes: [],
            spiciness: "none",
            dislikedIngredients: [],
            dietGoals: ["控盐", "控糖"],
            preferredSports: [],
            avoidedSports: [],
            facilities: [],
            intensityCeiling: "中",
            region: "广东",
            ageDecade: "60s"
        )
    }

    @Test func bundledRulesLoad() {
        let rules = DietGuidelineRules.load()
        #expect(!rules.constraints.isEmpty)
        #expect(rules.clauses.count >= 5)
    }

    @Test func hypertensionConstraintBlocksHighSaltTaggedRecipe() {
        let rules = DietGuidelineRules.load()
        let recipes = [
            Recipe(
                id: "low-salt",
                name: "清蒸鱼",
                cuisine: "粤菜",
                spiciness: "none",
                tags: ["低盐"],
                ingredients: ["鱼"],
                avoidFor: [],
                suitableFor: ["高血压"],
                mealType: ["晚餐"],
                cookingNote: ""
            ),
            Recipe(
                id: "high-salt",
                name: "腊肉煲",
                cuisine: "湘菜",
                spiciness: "medium",
                tags: ["高盐", "腌制"],
                ingredients: ["腊肉"],
                avoidFor: [],
                suitableFor: [],
                mealType: ["晚餐"],
                cookingNote: ""
            ),
        ]
        let filtered = DietTools.filterSafeRecipes(recipes, profile: hypertensiveProfile, dietRules: rules)
        #expect(filtered.map(\.id) == ["low-salt"])
    }

    @Test func relevantClausesMatchConditions() {
        let rules = DietGuidelineRules.load()
        let clauses = rules.relevantClauses(for: hypertensiveProfile, limit: 8)
        #expect(rules.clauses.contains { $0.id == "CL-HTN-101" })
        #expect(rules.clauses.contains { $0.id == "CL-DIA-101" })
        #expect(clauses.contains { $0.tags.contains("高血压") || $0.tags.contains("糖尿病") })
    }

    @Test func lookupClausesSupportsKeywordQuery() {
        let rules = DietGuidelineRules.load()
        let clauses = DietTools.lookupClauses(
            profile: hypertensiveProfile,
            dietRules: rules,
            query: "升糖指数"
        )
        #expect(clauses.contains { $0.id == "CL-DIA-101" })
    }
}

struct DietToolsTests {
    @Test func validateAgentReplyRejectsUnknownRecipe() {
        let rules = GuidelineRules.load()
        #expect(
            DietTools.validateAgentReply(
                text: "建议尝试清淡饮食",
                citedRecipeIDs: ["recipe-x"],
                citedClauseIDs: [],
                allowedRecipeIDs: ["recipe-001"],
                allowedClauseIDs: ["CL-HTN-101"],
                guardrailRules: rules
            ) == false
        )
    }

    @Test func cloudDietAgentMockFallbackWorks() async throws {
        let profile = ProfileTags(
            conditions: ["高血压"],
            foodAllergies: [],
            injuries: [],
            doctorRestrictions: [],
            cuisineLikes: ["粤菜"],
            cuisineDislikes: [],
            spiciness: "none",
            dislikedIngredients: [],
            dietGoals: ["控盐"],
            preferredSports: [],
            avoidedSports: [],
            facilities: [],
            intensityCeiling: "中",
            region: "广东",
            ageDecade: "60s"
        )
        let context = DietAgentContext(
            profile: profile,
            trendSummary: "睡眠 z=-1.0",
            todayStatus: "稳定",
            recipes: ContentLibrary.loadRecipes(),
            dietRules: DietGuidelineRules.load(),
            guardrailRules: GuidelineRules.load(),
            history: []
        )
        let response = try await CloudDietAgent(llm: MockLLMProvider()).respond(to: "今晚吃什么？", context: context)
        #expect(!response.reply.isEmpty)
        #expect(response.citedRecipeIDs.allSatisfy { context.recipes.map(\.id).contains($0) || response.degraded })
    }
}
