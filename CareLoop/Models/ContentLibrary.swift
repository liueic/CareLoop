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

enum ContentLibrary {
    static func loadRecipes() -> [Recipe] {
        Bundle.main.decodeJSON("recipes") ?? []
    }

    static func loadExercises() -> [ExerciseItem] {
        Bundle.main.decodeJSON("exercises") ?? []
    }
}
