import Foundation

struct DietConstraint: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var conditions: [String]
    var dietGoals: [String]
    var forbidIngredients: [String]
    var forbiddenTags: [String]
    var requiredTagsAny: [String]
    var notes: String
}

struct DietClause: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var body: String
    var tags: [String]
    var source: String
}

struct DietGuidelineRules: Codable, Sendable {
    var version: String
    var disclaimer: String
    var constraints: [DietConstraint]
    var clauses: [DietClause]

    static func load() -> DietGuidelineRules {
        if let rules: DietGuidelineRules = Bundle.main.decodeJSON("diet_rules") {
            return rules
        }
        return DietGuidelineRules(
            version: "fallback",
            disclaimer: CareLoopCopy.medicalDisclaimer,
            constraints: [],
            clauses: [
                DietClause(
                    id: "CL-GEN-101",
                    title: "通用安全提醒",
                    body: "饮食建议仅供参考，不构成医疗建议。",
                    tags: ["通用"],
                    source: "fallback"
                ),
            ]
        )
    }

    func applicableConstraints(for profile: ProfileTags) -> [DietConstraint] {
        constraints.filter { constraint in
            let conditionHit = !Set(constraint.conditions).isDisjoint(with: profile.conditions)
            let goalHit = !Set(constraint.dietGoals).isDisjoint(with: profile.dietGoals)
            return conditionHit || goalHit
        }
    }

    func mergedForbiddenIngredients(for profile: ProfileTags) -> Set<String> {
        var merged = Set(profile.foodAllergies + profile.dislikedIngredients)
        for constraint in applicableConstraints(for: profile) {
            merged.formUnion(constraint.forbidIngredients)
        }
        return merged
    }

    func mergedForbiddenTags(for profile: ProfileTags) -> Set<String> {
        var merged = Set<String>()
        for constraint in applicableConstraints(for: profile) {
            merged.formUnion(constraint.forbiddenTags)
        }
        return merged
    }

    func relevantClauses(
        for profile: ProfileTags,
        keywords: [String] = [],
        limit: Int = 5
    ) -> [DietClause] {
        let tags = Set(profile.conditions + profile.dietGoals + ["通用"])
        let loweredKeywords = keywords.map { $0.lowercased() }.filter { !$0.isEmpty }
        let scored = clauses.map { clause -> (DietClause, Int) in
            var score = 0
            for tag in clause.tags where tags.contains(tag) { score += 4 }
            if !profile.foodAllergies.isEmpty && clause.tags.contains("过敏") { score += 3 }
            if loweredKeywords.isEmpty {
                return (clause, score)
            }
            let haystack = "\(clause.title) \(clause.body) \(clause.tags.joined(separator: " "))".lowercased()
            for keyword in loweredKeywords where haystack.contains(keyword) {
                score += 2
            }
            return (clause, score)
        }
        .filter { $0.1 > 0 || ($0.0.tags.contains("通用") && loweredKeywords.isEmpty) }
        .sorted { lhs, rhs in
            if lhs.1 == rhs.1 { return lhs.0.id < rhs.0.id }
            return lhs.1 > rhs.1
        }
        return Array(scored.prefix(limit).map(\.0))
    }

    func clauses(withIDs ids: [String]) -> [DietClause] {
        let lookup = Dictionary(uniqueKeysWithValues: clauses.map { ($0.id, $0) })
        return ids.compactMap { lookup[$0] }
    }
}

enum DietGuidelineStore {
    static func shared() -> DietGuidelineRules {
        DietGuidelineRules.load()
    }
}
