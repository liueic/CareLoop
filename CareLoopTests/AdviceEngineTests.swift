import Foundation
@testable import CareLoop
import Testing

struct AdviceEngineTests {
    private var heartProfile: ProfileTags {
        ProfileTags(
            conditions: ["心脏病", "房颤"],
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

    @Test func heartDiseaseDropsHighIntensity() {
        let exercises = ContentLibrary.loadExercises()
        let filtered = AdviceEngine.hardFilterExercises(
            exercises,
            profile: heartProfile,
            feelingUnwell: false,
            rules: GuidelineRules.load()
        )
        #expect(!filtered.contains { $0.name == "HIIT" || $0.name.contains("短跑") || $0.level == .high })
        #expect(filtered.contains { $0.name == "快走" || $0.name == "散步" })
    }

    @Test func guangdongNoSpicyAndAllergy() {
        let recipes = [
            Recipe(id: "a", name: "清蒸鲈鱼", cuisine: "粤菜", spiciness: "none", tags: [], ingredients: ["鲈鱼"], avoidFor: [], suitableFor: ["高血压"], mealType: ["午餐"], cookingNote: ""),
            Recipe(id: "b", name: "水煮牛肉", cuisine: "川菜", spiciness: "hot", tags: [], ingredients: ["牛肉"], avoidFor: [], suitableFor: [], mealType: ["午餐"], cookingNote: ""),
            Recipe(id: "c", name: "白灼虾", cuisine: "粤菜", spiciness: "none", tags: [], ingredients: ["虾"], avoidFor: [], suitableFor: [], mealType: ["午餐"], cookingNote: ""),
        ]
        let filtered = AdviceEngine.hardFilterRecipes(recipes, profile: heartProfile)
        #expect(filtered.map(\.id) == ["a"])
    }

    @Test func postValidateRejectsBlacklistAndOutOfSet() async {
        let rules = GuidelineRules.load()
        #expect(AdviceEngine.postValidate(text: "建议停药观察", citedIDs: ["recipe-001"], allowedIDs: ["recipe-001"], rules: rules) == false)
        #expect(AdviceEngine.postValidate(text: "清淡饮食", citedIDs: ["x"], allowedIDs: ["recipe-001"], rules: rules) == false)
        #expect(AdviceEngine.postValidate(text: "清淡饮食", citedIDs: ["recipe-001"], allowedIDs: ["recipe-001"], rules: rules))
    }

    @Test func mockLLMFallbackStillWorks() async {
        let recipes = ContentLibrary.loadRecipes()
        #expect(recipes.count >= 40)
        let exercises = ContentLibrary.loadExercises()
        #expect(exercises.count >= 20)
        let output = await AdviceEngine.run(
            input: AdvicePipelineInput(
                profile: heartProfile,
                recipes: recipes,
                exercises: exercises,
                trendSummary: "睡眠 z=-2.1",
                feelingUnwell: true,
                todayStatus: "值得关注"
            ),
            llm: MockLLMProvider(),
            rules: GuidelineRules.load()
        )
        #expect(!output.safeExerciseIDs.isEmpty)
        #expect(output.exercise.citedIDs.allSatisfy { output.safeExerciseIDs.contains($0) })
        #expect(output.recipe.body.isEmpty == false)
    }

    @Test func unwellForcesLowIntensity() {
        let filtered = AdviceEngine.hardFilterExercises(
            ContentLibrary.loadExercises(),
            profile: heartProfile,
            feelingUnwell: true,
            rules: GuidelineRules.load()
        )
        #expect(filtered.allSatisfy { $0.level == .low })
    }
}
