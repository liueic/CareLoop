import Foundation
import SwiftData

@Model
final class UserProfile {
    var createdAt: Date
    var updatedAt: Date
    var birthDate: Date?
    var biologicalSexRaw: String
    var bloodTypeRaw: String
    var heightCM: Double?
    var weightKG: Double?
    var wheelchairUseRaw: String
    var conditions: [String]
    var drugAllergies: [String]
    var foodAllergies: [String]
    var injuries: [String]
    var doctorRestrictions: [String]
    var currentMedicationNames: [String]
    var regionProvince: String
    var regionCity: String
    var cuisineLikes: [String]
    var cuisineDislikes: [String]
    var spicinessRaw: String
    var dislikedIngredients: [String]
    var cookFrequencyRaw: String
    var dietGoals: [String]
    var preferredSports: [String]
    var avoidedSports: [String]
    var exerciseFrequencyRaw: String
    var timePreferenceRaw: String
    var facilities: [String]
    var intensityCeilingRaw: String
    var reminderHour: Int
    var reminderMinute: Int
    var showBPOnWatermark: Bool
    var showGlucoseOnWatermark: Bool
    var onboardingCompleted: Bool

    init() {
        let now = Date()
        createdAt = now
        updatedAt = now
        biologicalSexRaw = BiologicalSex.unspecified.rawValue
        bloodTypeRaw = BloodType.unknown.rawValue
        wheelchairUseRaw = WheelchairUse.unspecified.rawValue
        conditions = []
        drugAllergies = []
        foodAllergies = []
        injuries = []
        doctorRestrictions = []
        currentMedicationNames = []
        regionProvince = ""
        regionCity = ""
        cuisineLikes = []
        cuisineDislikes = []
        spicinessRaw = Spiciness.none.rawValue
        dislikedIngredients = []
        cookFrequencyRaw = CookFrequency.fewTimesWeek.rawValue
        dietGoals = []
        preferredSports = []
        avoidedSports = []
        exerciseFrequencyRaw = ExerciseFrequency.weekly.rawValue
        timePreferenceRaw = TimePreference.flexible.rawValue
        facilities = []
        intensityCeilingRaw = IntensityLevel.low.rawValue
        reminderHour = 19
        reminderMinute = 30
        showBPOnWatermark = false
        showGlucoseOnWatermark = false
        onboardingCompleted = false
    }

    var biologicalSex: BiologicalSex {
        get { BiologicalSex(rawValue: biologicalSexRaw) ?? .unspecified }
        set { biologicalSexRaw = newValue.rawValue }
    }

    var bloodType: BloodType {
        get { BloodType(rawValue: bloodTypeRaw) ?? .unknown }
        set { bloodTypeRaw = newValue.rawValue }
    }

    var wheelchairUse: WheelchairUse {
        get { WheelchairUse(rawValue: wheelchairUseRaw) ?? .unspecified }
        set { wheelchairUseRaw = newValue.rawValue }
    }

    var spiciness: Spiciness {
        get { Spiciness(rawValue: spicinessRaw) ?? .none }
        set { spicinessRaw = newValue.rawValue }
    }

    var cookFrequency: CookFrequency {
        get { CookFrequency(rawValue: cookFrequencyRaw) ?? .fewTimesWeek }
        set { cookFrequencyRaw = newValue.rawValue }
    }

    var exerciseFrequency: ExerciseFrequency {
        get { ExerciseFrequency(rawValue: exerciseFrequencyRaw) ?? .weekly }
        set { exerciseFrequencyRaw = newValue.rawValue }
    }

    var timePreference: TimePreference {
        get { TimePreference(rawValue: timePreferenceRaw) ?? .flexible }
        set { timePreferenceRaw = newValue.rawValue }
    }

    var intensityCeiling: IntensityLevel {
        get { IntensityLevel(rawValue: intensityCeilingRaw) ?? .low }
        set { intensityCeilingRaw = newValue.rawValue }
    }

    var parsedConditions: [ChronicCondition] {
        conditions.compactMap(ChronicCondition.init(rawValue:))
    }

    var completionScore: Double {
        var filled = 0.0
        let total = 8.0
        if birthDate != nil { filled += 1 }
        if biologicalSex != .unspecified { filled += 1 }
        if heightCM != nil && weightKG != nil { filled += 1 }
        if !conditions.isEmpty { filled += 1 }
        if !regionProvince.isEmpty { filled += 1 }
        if !cuisineLikes.isEmpty || spiciness != .none { filled += 1 }
        if !preferredSports.isEmpty { filled += 1 }
        if onboardingCompleted { filled += 1 }
        return filled / total
    }

    func applyConditionConstraints() {
        let ceilings = parsedConditions.map(\.intensityCeiling)
        intensityCeiling = ceilings.min() ?? .low
        for condition in parsedConditions {
            for goal in condition.defaultDietGoals where !dietGoals.contains(goal.rawValue) {
                dietGoals.append(goal.rawValue)
            }
        }
        if parsedConditions.contains(where: { $0 == .atrialFibrillation || $0 == .heartDisease }) {
            for sport in ["HIIT", "短跑", "篮球对抗", "足球对抗"] where !avoidedSports.contains(sport) {
                avoidedSports.append(sport)
            }
        }
        if regionProvince.contains("广东") || regionProvince.contains("粤") {
            spiciness = .none
        }
        updatedAt = Date()
    }

    func desensitizedTags() -> ProfileTags {
        ProfileTags(
            conditions: conditions,
            foodAllergies: foodAllergies,
            injuries: injuries,
            doctorRestrictions: doctorRestrictions,
            cuisineLikes: cuisineLikes,
            cuisineDislikes: cuisineDislikes,
            spiciness: spiciness.jsonValue,
            dislikedIngredients: dislikedIngredients,
            dietGoals: dietGoals,
            preferredSports: preferredSports,
            avoidedSports: avoidedSports,
            facilities: facilities,
            intensityCeiling: intensityCeilingRaw,
            region: regionProvince.isEmpty ? nil : regionProvince,
            ageDecade: birthDate.map { decade(of: $0) }
        )
    }

    private func decade(of date: Date) -> String {
        let age = Calendar.current.dateComponents([.year], from: date, to: Date()).year ?? 0
        let bucket = (max(age, 0) / 10) * 10
        return "\(bucket)s"
    }
}

struct ProfileTags: Codable, Hashable, Sendable {
    var conditions: [String]
    var foodAllergies: [String]
    var injuries: [String]
    var doctorRestrictions: [String]
    var cuisineLikes: [String]
    var cuisineDislikes: [String]
    var spiciness: String
    var dislikedIngredients: [String]
    var dietGoals: [String]
    var preferredSports: [String]
    var avoidedSports: [String]
    var facilities: [String]
    var intensityCeiling: String
    var region: String?
    var ageDecade: String?
}
