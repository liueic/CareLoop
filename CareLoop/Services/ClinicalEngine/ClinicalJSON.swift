import Foundation

/// 可发送的 JSON 树，用来原样保留规则 YAML/JSON 里的 conditions。
enum ClinicalJSON: Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([ClinicalJSON])
    case object([String: ClinicalJSON])
    case null

    static func from(_ any: Any?) -> ClinicalJSON {
        switch any {
        case nil:
            return .null
        case let value as ClinicalJSON:
            return value
        case let value as String:
            return .string(value)
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .number(Double(value))
        case let value as Double:
            return .number(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        case let value as [Any]:
            return .array(value.map { from($0) })
        case let value as [String: Any]:
            return .object(value.mapValues { from($0) })
        default:
            return .null
        }
    }

    var object: [String: ClinicalJSON]? {
        if case let .object(value) = self { return value }
        return nil
    }

    var array: [ClinicalJSON]? {
        if case let .array(value) = self { return value }
        return nil
    }

    var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var number: Double? {
        switch self {
        case let .number(value): value
        case let .string(value): Double(value)
        case let .bool(value): value ? 1 : 0
        default: nil
        }
    }

    subscript(_ key: String) -> ClinicalJSON? {
        object?[key]
    }

    func stringValue(_ key: String) -> String? {
        self[key]?.string
    }

    func doubleValue(_ key: String) -> Double? {
        self[key]?.number
    }

    func intValue(_ key: String, default defaultValue: Int) -> Int {
        if let number = self[key]?.number {
            return Int(number)
        }
        return defaultValue
    }

    func boolValue(_ key: String, default defaultValue: Bool) -> Bool {
        self[key]?.bool ?? defaultValue
    }

    func stringArray(_ key: String) -> [String] {
        guard let items = self[key]?.array else { return [] }
        return items.compactMap(\.string)
    }

    var displayText: String {
        switch self {
        case let .string(value):
            value
        case let .number(value):
            value.rounded() == value ? String(Int(value)) : String(value)
        case let .bool(value):
            value ? "true" : "false"
        case let .array(values):
            values.map(\.displayText).joined(separator: ",")
        case let .object(values):
            values.map { "\($0)=\($1.displayText)" }.sorted().joined(separator: ", ")
        case .null:
            ""
        }
    }
}
