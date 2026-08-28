import Foundation

struct GuidelineRules: Codable, Sendable {
    var version: String
    var disclaimer: String
    var populationThresholds: [String: Threshold]
    var redFlagKeywords: [String]
    var adviceBlacklist: [String]
    var conditionIntensityCeiling: [String: String]
    var highSugarTags: [String]
    var wearableDeviceNotes: [String: String]?

    struct Threshold: Codable, Sendable {
        var low: Double?
        var high: Double?
        var unit: String?
        var guideline: String?
    }

    static func load() -> GuidelineRules {
        if let rules: GuidelineRules = Bundle.main.decodeJSON("guidelines") {
            return rules
        }
        return GuidelineRules(
            version: "fallback",
            disclaimer: CareLoopCopy.medicalDisclaimer,
            populationThresholds: [:],
            redFlagKeywords: ["胸痛", "严重头晕", "呼吸困难"],
            adviceBlacklist: ["停药", "加量", "治愈", "确诊"],
            conditionIntensityCeiling: ["房颤": "低", "心脏病": "低"],
            highSugarTags: ["含糖饮料", "高糖"]
        )
    }
}

extension Bundle {
    func decodeJSON<T: Decodable>(_ name: String) -> T? {
        let candidates = [
            url(forResource: name, withExtension: "json"),
            url(forResource: name, withExtension: "json", subdirectory: "Content"),
            url(forResource: name, withExtension: "json", subdirectory: "Rules"),
            url(forResource: name, withExtension: "json", subdirectory: "DietRules"),
            url(forResource: name, withExtension: "json", subdirectory: "ClinicalRules"),
            url(forResource: name, withExtension: "json", subdirectory: "Resources/Content"),
            url(forResource: name, withExtension: "json", subdirectory: "Resources/Rules"),
            url(forResource: name, withExtension: "json", subdirectory: "Resources/DietRules"),
            url(forResource: name, withExtension: "json", subdirectory: "Resources/ClinicalRules"),
        ]
        if let url = candidates.compactMap({ $0 }).first,
           let data = try? Data(contentsOf: url) {
            return try? JSONDecoder().decode(T.self, from: data)
        }
        if let urls = urls(forResourcesWithExtension: "json", subdirectory: nil),
           let url = urls.first(where: { $0.deletingPathExtension().lastPathComponent == name }),
           let data = try? Data(contentsOf: url) {
            return try? JSONDecoder().decode(T.self, from: data)
        }
        return nil
    }
}
