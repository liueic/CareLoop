import Foundation

enum DietGuidelineCompiler {
    private static let dietKeywords = [
        "饮食", "钠", "盐", "碳水", "糖", "脂肪", "胆固醇", "进餐",
        "低盐", "低脂", "纤维", "升糖", "热量", "烹调", "钾",
    ]

    static func mergedWithClinicalAdvice(
        _ bundled: DietGuidelineRules,
        adviceData: Data? = nil
    ) -> DietGuidelineRules {
        let data = adviceData ?? loadAdviceData()
        guard let data else { return bundled }

        var clauses = bundled.clauses
        var seenIDs = Set(clauses.map(\.id))
        var seenBodies = Set(clauses.map(\.body))

        for item in parsedAdvice(from: data) {
            guard isDietRelated(title: item.title, body: item.body) else { continue }
            let identifier = clauseID(fromAdviceID: item.id)
            if seenIDs.contains(identifier) || seenBodies.contains(item.body) { continue }
            seenIDs.insert(identifier)
            seenBodies.insert(item.body)
            clauses.append(
                DietClause(
                    id: identifier,
                    title: item.title,
                    body: item.body,
                    tags: item.tags,
                    source: "ClinicalRules \(item.id)"
                )
            )
        }

        return DietGuidelineRules(
            version: bundled.version.hasSuffix("+clinical") ? bundled.version : "\(bundled.version)+clinical",
            disclaimer: bundled.disclaimer,
            constraints: bundled.constraints,
            clauses: clauses
        )
    }

    static func isDietRelated(title: String, body: String) -> Bool {
        let haystack = "\(title) \(body)"
        return dietKeywords.contains { haystack.contains($0) }
    }

    static func clauseID(fromAdviceID adviceID: String) -> String {
        if adviceID.hasPrefix("CL-") { return adviceID }
        return "CL-\(adviceID)"
    }

    private static func loadAdviceData() -> Data? {
        let bundle = Bundle.main
        let candidates = [
            bundle.url(forResource: "advice", withExtension: "json", subdirectory: "ClinicalRules"),
            bundle.url(forResource: "advice", withExtension: "json", subdirectory: "Resources/ClinicalRules"),
            bundle.url(forResource: "advice", withExtension: "json"),
        ]
        if let url = candidates.compactMap({ $0 }).first {
            return try? Data(contentsOf: url)
        }
        if let urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) {
            return urls.first { $0.deletingPathExtension().lastPathComponent == "advice" }.flatMap { try? Data(contentsOf: $0) }
        }
        return nil
    }

    private static func parsedAdvice(from data: Data) -> [(id: String, title: String, body: String, tags: [String])] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["advice"] as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let id = item["id"] as? String,
                  let title = item["title_cn"] as? String,
                  let body = item["text_cn"] as? String else {
                return nil
            }
            let category = item["disease_category"] as? String ?? ""
            return (id, title, body, tags(for: category, title: title, body: body))
        }
    }

    private static func tags(for category: String, title: String, body: String) -> [String] {
        var tags: [String] = []
        switch category {
        case "hypertension": tags.append(contentsOf: ["高血压", "控盐"])
        case "diabetes": tags.append(contentsOf: ["糖尿病", "控糖"])
        case "dyslipidemia": tags.append(contentsOf: ["低脂"])
        case "composite": tags.append(contentsOf: ["心脏病", "控盐", "低脂"])
        default: break
        }
        if body.contains("盐") || body.contains("钠") { tags.append("控盐") }
        if body.contains("糖") || body.contains("碳水") || title.contains("饮食控制") { tags.append("控糖") }
        if tags.isEmpty { tags.append("通用") }
        return Array(Set(tags))
    }
}
