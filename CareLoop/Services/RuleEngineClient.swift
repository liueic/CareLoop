import Foundation

struct RuleEngineClient {
    let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    init(baseURL: URL = URL(string: "http://localhost:8000")!) {
        self.baseURL = baseURL
        self.session = URLSession(configuration: .default)
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Request / Response Models

    struct EvaluationRequest: Encodable {
        var measurements: [String: Double]
        var user_profile: [String: AnyCodableValue]?
        var history: [[String: AnyCodableValue]]?
        var version: String?
    }

    struct EvaluationResponse: Decodable, Sendable {
        var evaluation_id: String
        var ruleset_version: String
        var ruleset_sha256: String
        var input_digest: String
        var evaluated_at: String
        var domains: [String: DomainResult]
        var data_quality: [DataQualityIssue]
        var disclaimer: String
    }

    struct DomainResult: Decodable, Sendable {
        var domain: String
        var risk_level: String
        var summary: String
        var triggered_rules: [TriggeredRule]
        var advice: [AdviceItem]
    }

    struct TriggeredRule: Decodable, Sendable {
        var rule_id: String
        var risk_level: String
        var evidence: [EvidenceRef]
        var confidence: String
        var data: [String: Double]?
        var tags: [String]
    }

    struct EvidenceRef: Decodable, Sendable {
        var guideline: String
        var section: String?
        var quote: String?
    }

    struct AdviceItem: Decodable, Sendable {
        var id: String
        var text: String
    }

    struct DataQualityIssue: Decodable, Sendable {
        var metric: String
        var value: Double
        var reason: String
    }

    // MARK: - API Calls

    func evaluatePoint(measurements: [String: Double], version: String? = nil) async throws -> EvaluationResponse {
        var body: [String: Any] = ["measurements": measurements]
        if let version { body["version"] = version }
        return try await post(path: "/api/v1/evaluate/point", body: body)
    }

    func evaluateFull(
        measurements: [String: Double],
        userProfile: [String: Any]? = nil,
        history: [[String: Any]]? = nil,
        version: String? = nil
    ) async throws -> EvaluationResponse {
        var body: [String: Any] = ["measurements": measurements]
        if let userProfile { body["user_profile"] = userProfile }
        if let history { body["history"] = history }
        if let version { body["version"] = version }
        return try await post(path: "/api/v1/evaluate", body: body)
    }

    func ingestMeasurements(userID: String, measurements: [[String: Any]]) async throws -> [String: Any] {
        let body: [String: Any] = ["measurements": measurements]
        return try await postRaw(path: "/api/v1/users/\(userID)/measurements", body: body)
    }

    // MARK: - Internal

    private func post(path: String, body: [String: Any]) async throws -> EvaluationResponse {
        let data = try await postRawData(path: path, body: body)
        return try decoder.decode(EvaluationResponse.self, from: data)
    }

    private func postRaw(path: String, body: [String: Any]) async throws -> [String: Any] {
        let data = try await postRawData(path: path, body: body)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RuleEngineError.invalidResponse
        }
        return json
    }

    private func postRawData(path: String, body: [String: Any]) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RuleEngineError.invalidResponse
        }
        if http.statusCode >= 400 {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw RuleEngineError.serverError(statusCode: http.statusCode, message: message)
        }
        return data
    }
}

enum RuleEngineError: LocalizedError {
    case invalidResponse
    case serverError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "规则引擎返回了无法解析的响应"
        case .serverError(let code, let msg):
            "规则引擎错误 (HTTP \(code)): \(msg)"
        }
    }
}

enum AnyCodableValue: Encodable {
    case string(String)
    case double(Double)
    case int(Int)
    case bool(Bool)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        }
    }
}
