import Foundation

struct DietAgentContext: Sendable {
    var profile: ProfileTags
    var trendSummary: String
    var todayStatus: String
    var recipes: [Recipe]
    var dietRules: DietGuidelineRules
    var guardrailRules: GuidelineRules
    var history: [(role: String, content: String)]
    var recentDietLogSummary: String
    var recentGlucose: String?
    var recentBloodPressure: String?
    var currentMedicationNames: [String]

    init(
        profile: ProfileTags,
        trendSummary: String,
        todayStatus: String,
        recipes: [Recipe],
        dietRules: DietGuidelineRules,
        guardrailRules: GuidelineRules,
        history: [(role: String, content: String)] = [],
        recentDietLogSummary: String = "",
        recentGlucose: String? = nil,
        recentBloodPressure: String? = nil,
        currentMedicationNames: [String] = []
    ) {
        self.profile = profile
        self.trendSummary = trendSummary
        self.todayStatus = todayStatus
        self.recipes = recipes
        self.dietRules = dietRules
        self.guardrailRules = guardrailRules
        self.history = history
        self.recentDietLogSummary = recentDietLogSummary
        self.recentGlucose = recentGlucose
        self.recentBloodPressure = recentBloodPressure
        self.currentMedicationNames = currentMedicationNames
    }
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

    static func lookupClausesHybrid(
        profile: ProfileTags,
        dietRules: DietGuidelineRules,
        query: String?,
        limit: Int = 5
    ) async -> [DietClause] {
        let tagged = lookupClauses(profile: profile, dietRules: dietRules, query: query, limit: limit)
        let spotlightIDs = await DietSpotlightIndexer.searchClauseIDs(matching: query ?? "")
        return mergeClauses(
            tagged: tagged,
            spotlightIDs: spotlightIDs,
            allClauses: dietRules.clauses,
            limit: limit
        )
    }

    static func mergeClauses(
        tagged: [DietClause],
        spotlightIDs: [String],
        allClauses: [DietClause],
        limit: Int
    ) -> [DietClause] {
        let lookup = Dictionary(uniqueKeysWithValues: allClauses.map { ($0.id, $0) })
        var seen = Set<String>()
        var result: [DietClause] = []
        for clause in tagged where seen.insert(clause.id).inserted {
            result.append(clause)
        }
        for identifier in spotlightIDs {
            guard seen.insert(identifier).inserted, let clause = lookup[identifier] else { continue }
            result.append(clause)
        }
        return Array(result.prefix(limit))
    }

    static func dietLogSummary(
        entries: [DailyLogEntry],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let todayDiet = entries.filter { entry in
            calendar.isDate(entry.createdAt, inSameDayAs: now)
                && entry.tags.contains(LogTag.diet.rawValue)
                && entry.confirmationState != .pendingAI
        }
        return todayDiet
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(5)
            .map(\.displayBody)
            .filter { !$0.isEmpty }
            .joined(separator: "；")
    }

    static func metricSummary(label: String, value: Double?, unit: String, source: String) -> String? {
        guard let value else { return nil }
        return "\(label) \(formatMetric(value)) \(unit)（来源：\(source)）"
    }

    static func bloodPressureSummary(systolic: Double?, diastolic: Double?, source: String) -> String? {
        guard let systolic, let diastolic else { return nil }
        return "血压 \(formatMetric(systolic, decimals: 0))/\(formatMetric(diastolic, decimals: 0)) mmHg（来源：\(source)）"
    }

    static func profileAndStatusJSON(context: DietAgentContext) -> String {
        var payload: [String: Any] = [
            "profile": (try? JSONSerialization.jsonObject(with: (try? JSONEncoder().encode(context.profile)) ?? Data())) ?? [:],
            "todayStatus": context.todayStatus,
            "trendSummary": context.trendSummary,
            "recentDietLogSummary": context.recentDietLogSummary,
            "medicationNames": context.currentMedicationNames,
            "medicationNote": "用药名称仅供提醒咨询医生或药师，禁止据此判断食物与药物相互作用或调整剂量。",
        ]
        if let recentGlucose = context.recentGlucose {
            payload["recentGlucose"] = recentGlucose
        }
        if let recentBloodPressure = context.recentBloodPressure {
            payload["recentBloodPressure"] = recentBloodPressure
        }
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

    private static func formatMetric(_ value: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", value)
    }
}
