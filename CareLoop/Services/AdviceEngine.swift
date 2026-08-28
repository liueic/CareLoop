import Foundation

struct AdvicePipelineInput: Sendable {
    var profile: ProfileTags
    var recipes: [Recipe]
    var exercises: [ExerciseItem]
    var trendSummary: String
    var feelingUnwell: Bool
    var todayStatus: String
}

struct AdvicePipelineOutput: Equatable, Sendable {
    var recipe: AdviceResult
    var exercise: AdviceResult
    var safeRecipeIDs: [String]
    var safeExerciseIDs: [String]
}

enum AdviceEngine: Sendable {
    static let promptRedLines = """
    红线：只能从给定候选中组合，不许发明候选之外的食谱或运动；不许讨论药物剂量、停药、加量、换药；不许做出诊断或治愈承诺；必须使用温和、可执行、可逆的建议。
    """

    static func run(
        input: AdvicePipelineInput,
        llm: any LLMProviding,
        rules: GuidelineRules
    ) async -> AdvicePipelineOutput {
        let recipes = hardFilterRecipes(input.recipes, profile: input.profile)
        let exercises = hardFilterExercises(
            input.exercises,
            profile: input.profile,
            feelingUnwell: input.feelingUnwell,
            rules: rules
        )
        let rankedRecipes = softRankRecipes(recipes, profile: input.profile)
        let rankedExercises = softRankExercises(exercises, profile: input.profile)

        let recipe = await generate(
            kind: .recipe,
            candidates: rankedRecipes.prefix(8).map {
                CandidateRef(id: $0.id, name: $0.name, extra: "\($0.cuisine)/\($0.spicinessLevel.rawValue)")
            },
            input: input,
            llm: llm,
            rules: rules,
            allowedIDs: Set(recipes.map(\.id))
        )
        let exercise = await generate(
            kind: .exercise,
            candidates: rankedExercises.prefix(8).map {
                CandidateRef(id: $0.id, name: $0.name, extra: "\($0.level.rawValue) MET\($0.intensityMET)")
            },
            input: input,
            llm: llm,
            rules: rules,
            allowedIDs: Set(exercises.map(\.id))
        )
        return AdvicePipelineOutput(
            recipe: recipe,
            exercise: exercise,
            safeRecipeIDs: recipes.map(\.id),
            safeExerciseIDs: exercises.map(\.id)
        )
    }

    static func hardFilterRecipes(_ recipes: [Recipe], profile: ProfileTags) -> [Recipe] {
        recipes.filter { recipe in
            if recipe.avoidFor.contains(where: { profile.conditions.contains($0) }) { return false }
            if recipe.ingredients.contains(where: { item in
                profile.foodAllergies.contains(where: { item.contains($0) })
                    || profile.dislikedIngredients.contains(where: { item.contains($0) })
            }) { return false }
            if profile.cuisineDislikes.contains(recipe.cuisine) { return false }
            if recipe.spicinessLevel.rank > Spiciness(jsonValue: profile.spiciness).rank { return false }
            return true
        }
    }

    static func hardFilterExercises(
        _ exercises: [ExerciseItem],
        profile: ProfileTags,
        feelingUnwell: Bool,
        rules: GuidelineRules
    ) -> [ExerciseItem] {
        let ceiling = resolvedCeiling(profile: profile, feelingUnwell: feelingUnwell, rules: rules)
        return exercises.filter { item in
            if item.avoidFor.contains(where: { profile.conditions.contains($0) || profile.injuries.contains($0) }) {
                return false
            }
            if profile.avoidedSports.contains(item.name) { return false }
            if item.level > ceiling { return false }
            if !profile.facilities.isEmpty {
                let ok = item.venue.isEmpty || item.venue.contains(where: { profile.facilities.contains($0) })
                    || item.requiresEquipment.allSatisfy { profile.facilities.contains($0) || $0.isEmpty }
                if !ok && !item.requiresEquipment.isEmpty {
                    let hasGear = item.requiresEquipment.allSatisfy { profile.facilities.contains($0) }
                    if !hasGear { return false }
                }
            }
            return true
        }
    }

    static func softRankRecipes(_ recipes: [Recipe], profile: ProfileTags) -> [Recipe] {
        recipes.sorted { lhs, rhs in
            scoreRecipe(lhs, profile: profile) > scoreRecipe(rhs, profile: profile)
        }
    }

    static func softRankExercises(_ exercises: [ExerciseItem], profile: ProfileTags) -> [ExerciseItem] {
        exercises.sorted { lhs, rhs in
            scoreExercise(lhs, profile: profile) > scoreExercise(rhs, profile: profile)
        }
    }

    static func postValidate(
        text: String,
        citedIDs: [String],
        allowedIDs: Set<String>,
        rules: GuidelineRules
    ) -> Bool {
        guard !citedIDs.isEmpty, citedIDs.allSatisfy({ allowedIDs.contains($0) }) else { return false }
        let lowered = text
        return !rules.adviceBlacklist.contains { lowered.contains($0) }
    }

    private static func generate(
        kind: AdviceResult.Kind,
        candidates: [CandidateRef],
        input: AdvicePipelineInput,
        llm: any LLMProviding,
        rules: GuidelineRules,
        allowedIDs: Set<String>
    ) async -> AdviceResult {
        let fallback = templateAdvice(kind: kind, candidates: candidates)
        guard !candidates.isEmpty else {
            return AdviceResult(
                kind: kind,
                title: kind == .recipe ? "今日饮食" : "今日活动",
                body: "当前没有通过安全过滤的候选，建议保持清淡饮食与低强度活动，并咨询医生。",
                citedIDs: [],
                usedLLM: false,
                degraded: true,
                disclaimer: CareLoopCopy.aiAdviceDisclaimer
            )
        }
        do {
            let prompt = buildPrompt(kind: kind, candidates: candidates, input: input)
            let response = try await llm.complete(prompt: prompt)
            let parsed = parse(response.text, fallbackIDs: candidates.map(\.id))
            if postValidate(text: parsed.body, citedIDs: parsed.ids, allowedIDs: allowedIDs, rules: rules) {
                return AdviceResult(
                    kind: kind,
                    title: parsed.title,
                    body: parsed.body,
                    citedIDs: parsed.ids,
                    usedLLM: true,
                    degraded: false,
                    disclaimer: CareLoopCopy.aiAdviceDisclaimer
                )
            }
        } catch {
            // fall through to template
        }
        return fallback
    }

    private static func templateAdvice(kind: AdviceResult.Kind, candidates: [CandidateRef]) -> AdviceResult {
        let pick = Array(candidates.prefix(3))
        let names = pick.map(\.name).joined(separator: "、")
        let ids = pick.map(\.id)
        let body: String
        if kind == .recipe {
            body = "从安全候选中为你准备了：\(names)。烹饪时少盐少糖，如有不适请停止并咨询医生。"
        } else {
            body = "今天优先选择低到中等强度：\(names)。以能够对话、不头晕为度，出现胸痛或严重不适请停止并就医。"
        }
        return AdviceResult(
            kind: kind,
            title: kind == .recipe ? "今日饮食建议" : "今日活动建议",
            body: body,
            citedIDs: ids,
            usedLLM: false,
            degraded: true,
            disclaimer: CareLoopCopy.aiAdviceDisclaimer
        )
    }

    private static func buildPrompt(kind: AdviceResult.Kind, candidates: [CandidateRef], input: AdvicePipelineInput) -> LLMPrompt {
        let candidateText = candidates.map { "- \($0.id) \($0.name) (\($0.extra))" }.joined(separator: "\n")
        let user = """
        你是慢病日常管理助手，不是医生。\(promptRedLines)
        画像标签：\(String(decoding: (try? JSONEncoder().encode(input.profile)) ?? Data(), as: UTF8.self))
        今日状态：\(input.todayStatus)
        近7天趋势：\(input.trendSummary)
        候选（必须从中选择，输出 citedIDs）：
        \(candidateText)
        请输出 JSON：{"title":"...","body":"...","citedIDs":["id"]}
        类型：\(kind == .recipe ? "饮食" : "运动")
        """
        return LLMPrompt(
            system: "你只能做个性化表达，不能越出候选和安全红线。所有建议标注仅供参考。",
            user: user,
            images: []
        )
    }

    private static func parse(_ text: String, fallbackIDs: [String]) -> (title: String, body: String, ids: [String]) {
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let title = obj["title"] as? String ?? "今日建议"
            let body = obj["body"] as? String ?? text
            let ids = obj["citedIDs"] as? [String] ?? fallbackIDs
            return (title, body, ids)
        }
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            let slice = String(text[start...end])
            return parse(slice, fallbackIDs: fallbackIDs)
        }
        return ("今日建议", text, Array(fallbackIDs.prefix(1)))
    }

    private static func scoreRecipe(_ recipe: Recipe, profile: ProfileTags) -> Int {
        var score = 0
        if profile.cuisineLikes.contains(recipe.cuisine) { score += 5 }
        if recipe.suitableFor.contains(where: { profile.conditions.contains($0) }) { score += 4 }
        if recipe.spicinessLevel.rank == Spiciness(jsonValue: profile.spiciness).rank { score += 2 }
        return score
    }

    private static func scoreExercise(_ item: ExerciseItem, profile: ProfileTags) -> Int {
        var score = 0
        if profile.preferredSports.contains(item.name) { score += 5 }
        if item.venue.contains(where: { profile.facilities.contains($0) }) { score += 2 }
        return score
    }

    private static func resolvedCeiling(
        profile: ProfileTags,
        feelingUnwell: Bool,
        rules: GuidelineRules
    ) -> IntensityLevel {
        if feelingUnwell { return .low }
        var ceiling = IntensityLevel(rawValue: profile.intensityCeiling) ?? .low
        for condition in profile.conditions {
            if let raw = rules.conditionIntensityCeiling[condition],
               let level = IntensityLevel(rawValue: raw),
               level < ceiling {
                ceiling = level
            }
        }
        return ceiling
    }
}

private struct CandidateRef: Sendable {
    var id: String
    var name: String
    var extra: String
}
