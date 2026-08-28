import CryptoKit
import Foundation

struct ClinicalMetricDefinition: Sendable {
    var unitCanonical: String
    var plausibleRange: (Double, Double)
    var conversions: [(from: String, op: String, factor: Double)]
}

struct ClinicalRule: Sendable {
    var id: String
    var name: [String: String]
    var type: String
    var priority: Int
    var enabled: Bool
    var required: [String]
    var windowDays: Int
    var minSamples: Int
    var conditions: ClinicalJSON
    var evidence: [(sourceID: String, section: String, quote: String?)]
    var confidence: String
    var adviceIDs: [String]
}

struct ClinicalSource: Sendable {
    var sourceID: String
    var title: String
}

struct ClinicalAdviceRecord: Sendable {
    var id: String
    var textCN: String
}

struct ClinicalRuleset: Sendable {
    var version: String
    var sources: [ClinicalSource]
    var rules: [ClinicalRule]
}

struct ClinicalRulesetRegistry: Sendable {
    var activeVersion: String
    var metrics: [String: ClinicalMetricDefinition]
    var advice: [ClinicalAdviceRecord]
    var disclaimerCN: String
    var rulesets: [String: ClinicalRuleset]
    var hashes: [String: String]

    static func loadBundled(bundle: Bundle = Bundle(for: ClinicalEngineBundleToken.self)) -> ClinicalRulesetRegistry {
        let manifestCandidates = [
            bundle.url(forResource: "manifest", withExtension: "json", subdirectory: "Resources/ClinicalRules"),
            bundle.url(forResource: "manifest", withExtension: "json", subdirectory: "ClinicalRules"),
            bundle.url(forResource: "manifest", withExtension: "json"),
        ].compactMap { $0 }
        if let manifest = manifestCandidates.first {
            return load(fromRoot: manifest.deletingLastPathComponent())
        }
        return load(fromRoot: URL(fileURLWithPath: "/nonexistent-clinical-kb"))
    }

    static func load(fromRoot root: URL) -> ClinicalRulesetRegistry {
        func loadJSON(_ name: String) -> ClinicalJSON {
            let url = root.appendingPathComponent(name).appendingPathExtension("json")
            guard let data = try? Data(contentsOf: url),
                  let raw = try? JSONSerialization.jsonObject(with: data) else {
                return .null
            }
            return ClinicalJSON.from(raw)
        }

        let manifest = loadJSON("manifest")
        let active = manifest.stringValue("active_version") ?? "2024.1"
        let metricsJSON = loadJSON("metrics")["metrics"]?.object ?? [:]
        var metrics: [String: ClinicalMetricDefinition] = [:]
        for (key, value) in metricsJSON {
            let range = value["plausible_range"]?.array ?? []
            let low = range.first?.number ?? 0
            let high = range.dropFirst().first?.number ?? 0
            var conversions: [(from: String, op: String, factor: Double)] = []
            for item in value["conversions"]?.array ?? [] {
                guard let from = item.stringValue("from"),
                      let op = item.stringValue("op"),
                      let factor = item.doubleValue("factor") else { continue }
                conversions.append((from, op, factor))
            }
            metrics[key] = ClinicalMetricDefinition(
                unitCanonical: value.stringValue("unit_canonical") ?? "",
                plausibleRange: (low, high),
                conversions: conversions
            )
        }

        let adviceJSON = loadJSON("advice")
        let disclaimer = adviceJSON["disclaimer"]?.stringValue("text_cn")
            ?? "本结果为健康管理提示，不构成医学诊断。如有不适请及时就医。"
        let advice = (adviceJSON["advice"]?.array ?? []).compactMap { item -> ClinicalAdviceRecord? in
            guard let id = item.stringValue("id") else { return nil }
            return ClinicalAdviceRecord(id: id, textCN: item.stringValue("text_cn") ?? "")
        }

        let versionDir = root.appendingPathComponent(active)
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: versionDir,
            includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "json" }

        var allRules: [ClinicalRule] = []
        var allSources: [ClinicalSource] = []
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let raw = try? JSONSerialization.jsonObject(with: data) else { continue }
            let root = ClinicalJSON.from(raw)
            guard let ruleset = root["ruleset"] else { continue }
            for source in ruleset["sources"]?.array ?? [] {
                if let id = source.stringValue("source_id"), let title = source.stringValue("title") {
                    allSources.append(ClinicalSource(sourceID: id, title: title))
                }
            }
            for ruleJSON in ruleset["rules"]?.array ?? [] {
                guard let id = ruleJSON.stringValue("id"), let type = ruleJSON.stringValue("type") else { continue }
                let inputs = ruleJSON["inputs"] ?? .null
                let window = inputs["window"] ?? .null
                var parsedEvidence: [(sourceID: String, section: String, quote: String?)] = []
                for item in ruleJSON["evidence"]?.array ?? [] {
                    guard let sourceID = item.stringValue("source_id") else { continue }
                    parsedEvidence.append((
                        sourceID,
                        item.stringValue("section") ?? "",
                        item.stringValue("quote")
                    ))
                }
                allRules.append(
                    ClinicalRule(
                        id: id,
                        name: (ruleJSON["name"]?.object ?? [:]).compactMapValues(\.string),
                        type: type,
                        priority: ruleJSON.intValue("priority", default: 100),
                        enabled: ruleJSON.boolValue("enabled", default: true),
                        required: inputs.stringArray("required"),
                        windowDays: window.intValue("days", default: 7),
                        minSamples: window.intValue("min_samples", default: 3),
                        conditions: ruleJSON["conditions"] ?? .null,
                        evidence: parsedEvidence,
                        confidence: ruleJSON.stringValue("confidence") ?? "unknown",
                        adviceIDs: ruleJSON.stringArray("advice_ids")
                    )
                )
            }
        }

        allRules.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.id < rhs.id
        }
        let merged = ClinicalRuleset(version: active, sources: allSources, rules: allRules)
        return ClinicalRulesetRegistry(
            activeVersion: active,
            metrics: metrics,
            advice: advice,
            disclaimerCN: disclaimer,
            rulesets: [active: merged],
            hashes: [active: hash(merged)]
        )
    }

    func ruleset(_ version: String? = nil) -> ClinicalRuleset {
        let key = version ?? activeVersion
        return rulesets[key] ?? rulesets[activeVersion] ?? ClinicalRuleset(version: key, sources: [], rules: [])
    }

    func sha256(_ version: String? = nil) -> String {
        hashes[version ?? activeVersion] ?? ""
    }

    func sourceTitle(_ sourceID: String, in ruleset: ClinicalRuleset) -> String {
        ruleset.sources.first { $0.sourceID == sourceID }?.title ?? "Unknown"
    }

    func adviceItems(_ ids: [String]) -> [ClinicalAdviceItem] {
        ids.compactMap { id in
            advice.first { $0.id == id }.map { ClinicalAdviceItem(id: $0.id, text: $0.textCN) }
        }
    }

    func convert(metric: String, value: Double, unit: String) -> Double {
        guard let def = metrics[metric] else { return value }
        if unit.isEmpty || unit == def.unitCanonical { return value }
        for conversion in def.conversions where conversion.from == unit {
            if conversion.op == "div" { return value / conversion.factor }
            if conversion.op == "mul" { return value * conversion.factor }
        }
        return value
    }

    func isPlausible(metric: String, value: Double) -> Bool {
        guard let def = metrics[metric] else { return true }
        return value >= def.plausibleRange.0 && value <= def.plausibleRange.1
    }

    private static func hash(_ ruleset: ClinicalRuleset) -> String {
        let payload = ruleset.rules.map(\.id).joined(separator: ",") + "|" + ruleset.version
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

final class ClinicalEngineBundleToken: NSObject {}
