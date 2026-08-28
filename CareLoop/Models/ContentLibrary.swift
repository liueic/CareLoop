import Foundation

struct Recipe: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var cuisine: String
    var spiciness: String
    var tags: [String]
    var ingredients: [String]
    var avoidFor: [String]
    var suitableFor: [String]
    var mealType: [String]
    var cookingNote: String

    var spicinessLevel: Spiciness { Spiciness(jsonValue: spiciness) }
}

struct ExerciseItem: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var intensityMET: Double
    var intensityLevel: String
    var avoidFor: [String]
    var requiresEquipment: [String]
    var venue: [String]
    var defaultDurationMin: Int
    var notes: String

    var level: IntensityLevel {
        IntensityLevel(rawValue: intensityLevel) ?? IntensityLevel.fromMET(intensityMET)
    }
}

struct AdviceResult: Codable, Hashable, Sendable {
    var kind: Kind
    var title: String
    var body: String
    var citedIDs: [String]
    var clauseCitationIDs: [String]
    var usedLLM: Bool
    var degraded: Bool
    var disclaimer: String

    enum Kind: String, Codable, Sendable {
        case recipe
        case exercise
    }
}

struct FoodCatalogEntry: Codable, Hashable, Sendable, Identifiable {
    var foodCode: String
    var shortDesc: String
    var longDesc: String
    var nObs: Int?
    var kcalPer100g: Double?
    var sodiumMgPer100g: Double?
    var sugarGPer100g: Double?
    var satfatGPer100g: Double?
    var fiberGPer100g: Double?

    var id: String { foodCode }

    enum CodingKeys: String, CodingKey {
        case foodCode = "food_code"
        case shortDesc = "short_desc"
        case longDesc = "long_desc"
        case nObs = "n_obs"
        case kcalPer100g = "kcal_per_100g"
        case sodiumMgPer100g = "sodium_mg_per_100g"
        case sugarGPer100g = "sugar_g_per_100g"
        case satfatGPer100g = "satfat_g_per_100g"
        case fiberGPer100g = "fiber_g_per_100g"
    }
}

enum ContentLibrary {
    static func loadRecipes() -> [Recipe] {
        Bundle.main.decodeJSON("recipes") ?? []
    }

    static func loadExercises() -> [ExerciseItem] {
        Bundle.main.decodeJSON("exercises") ?? []
    }

    static func loadFoodCatalog() -> [FoodCatalogEntry] {
        Bundle.main.decodeJSON("food_catalog_slim") ?? []
    }
}
