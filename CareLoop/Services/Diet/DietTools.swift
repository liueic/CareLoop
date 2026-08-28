import Foundation

struct DietAgentContext: Sendable {
    var profile: ProfileTags
    var trendSummary: String
    var todayStatus: String
    var recipes: [Recipe]
    var dietRules: DietGuidelineRules
    var guardrailRules: GuidelineRules
    var history: [(role: String, content: String)]
}

struct DietAgentResponse: Equatable, Sendable {
    var reply: String
    var citedRecipeIDs: [String]
    var citedClauseIDs: [String]
    var usedLLM: Bool
    var degraded: Bool
    var disclaimer: String
}

enum DietTools: Sendable {
    static func filterSafeRecipes(
        _ recipes: [Recipe],
        profile: ProfileTags,
        dietRules: DietGuidelineRules
    ) -> [Recipe] {
        AdviceEngine.hardFilterRecipes(recipes, profile: profile, dietRules: dietRules)
    }

    static func lookupClauses(
        profile: ProfileTags,
        dietRules: DietGuidelineRules,
        query: String?,
        limit: Int = 5
    ) -> [DietClause] {
        let keywords = query?
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init) ?? []
        return dietRules.relevantClauses(for: profile, keywords: keywords, limit: limit)
    }

    static func profileAndStatusJSON(context: DietAgentContext) -> String {
        let payload: [String: Any] = [
            "profile": (try? JSONSerialization.jsonObject(with: (try? JSONEncoder().encode(context.profile)) ?? Data())) ?? [:],
            "todayStatus": context.todayStatus,
            "trendSummary": context.trendSummary,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    static func recipesJSON(_ recipes: [Recipe], limit: Int = 12) -> String {
        let payload = recipes.prefix(limit).map { recipe in
            [
                "id": recipe.id,
                "name": recipe.name,
                "cuisine": recipe.cuisine,
                "tags": recipe.tags,
                "mealType": recipe.mealType,
                "cookingNote": recipe.cookingNote,
            ] as [String: Any]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    static func clausesJSON(_ clauses: [DietClause]) -> String {
        let payload = clauses.map { clause in
            [
                "id": clause.id,
                "title": clause.title,
                "body": clause.body,
                "source": clause.source,
            ] as [String: Any]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    static func validateAgentReply(
        text: String,
        citedRecipeIDs: [String],
        citedClauseIDs: [String],
        allowedRecipeIDs: Set<String>,
        allowedClauseIDs: Set<String>,
        guardrailRules: GuidelineRules
    ) -> Bool {
        guard AdviceEngine.postValidate(
            text: text,
            citedIDs: citedRecipeIDs,
            allowedIDs: allowedRecipeIDs,
            rules: guardrailRules
        ) else { return false }
        guard !citedClauseIDs.isEmpty else { return true }
        return citedClauseIDs.allSatisfy { allowedClauseIDs.contains($0) }
    }

    static func parseAgentJSON(_ text: String) -> (reply: String, recipeIDs: [String], clauseIDs: [String]) {
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let reply = obj["reply"] as? String ?? obj["body"] as? String ?? text
            let recipeIDs = obj["citedRecipeIDs"] as? [String] ?? obj["citedIDs"] as? [String] ?? []
            let clauseIDs = obj["citedClauseIDs"] as? [String] ?? []
            return (reply, recipeIDs, clauseIDs)
        }
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            return parseAgentJSON(String(text[start...end]))
        }
        return (text, [], [])
    }
}
