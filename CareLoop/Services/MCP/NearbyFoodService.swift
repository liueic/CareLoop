import Foundation

/// 附近餐厅条目。经纬度只留在客户端用于构建导航链接，不进入 LLM 上下文。
struct NearbyPlace: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var type: String
    var address: String
    var distanceMeters: Int?
    var longitude: Double
    var latitude: Double

    /// 高德通用链接：已安装则唤起 App，否则打开网页版。坐标为高德系（gcj02），无需转换。
    var navigationURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "uri.amap.com"
        components.path = "/navigation"
        components.queryItems = [
            URLQueryItem(name: "to", value: "\(longitude),\(latitude),\(name)"),
            URLQueryItem(name: "mode", value: "walk"),
            URLQueryItem(name: "coordinate", value: "gaode"),
            URLQueryItem(name: "src", value: "careloop"),
            URLQueryItem(name: "policy", value: "1"),
        ]
        return components.url ?? URL(string: "https://uri.amap.com/navigation")!
    }

    var distanceText: String? {
        guard let distanceMeters else { return nil }
        if distanceMeters >= 1000 {
            return String(format: "%.1f km", Double(distanceMeters) / 1000)
        }
        return "\(distanceMeters) m"
    }
}

struct NearbyFoodSearchResult: Sendable {
    var places: [NearbyPlace]
    /// 机器可读错误码：no_key / location_denied / location_timeout / location_unavailable / network / server_error / empty
    var error: String?
    /// 给模型的处理建议（如「请建议用户到系统设置开启定位」）。
    var hint: String?

    static func failure(_ code: String, hint: String) -> NearbyFoodSearchResult {
        NearbyFoodSearchResult(places: [], error: code, hint: hint)
    }
}

/// 「附近吃什么」组合工具：定位 → 高德 maps-around-search → 精简 POI 列表。
/// 模型只见 keywords / radius 两个参数，经纬度在客户端注入。
protocol NearbyFoodSearching: Sendable {
    var isConfigured: Bool { get }
    func search(keywords: String?, radiusMeters: Int?) async -> NearbyFoodSearchResult
}

enum NearbyFoodJSON {
    /// 回填给模型的精简视图：{"places":[{"id","name","type","address","distance_m"}]} 或 {"error","hint"}。
    static func modelPayload(_ result: NearbyFoodSearchResult) -> String {
        var payload: [String: Any]
        if let error = result.error {
            payload = ["error": error]
            if let hint = result.hint {
                payload["hint"] = hint
            }
        } else {
            payload = [
                "places": result.places.prefix(8).map { place -> [String: Any] in
                    var item: [String: Any] = [
                        "id": place.id,
                        "name": place.name,
                        "type": place.type,
                        "address": place.address,
                    ]
                    if let distanceMeters = place.distanceMeters {
                        item["distance_m"] = distanceMeters
                    }
                    return item
                },
                "note": "可把选中的 place id 填入 citedPOIIDs；这些是位置参考信息，健康评价请基于指南条款",
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"empty\"}"
        }
        return text
    }
}

struct NearbyFoodService: NearbyFoodSearching {
    let client: any MCPRemoteToolProviding
    let location: any LocationProviding

    var isConfigured: Bool { client.isConfigured }

    func search(keywords: String?, radiusMeters: Int?) async -> NearbyFoodSearchResult {
        guard isConfigured else {
            return .failure("no_key", hint: "未配置高德 Key，附近搜索不可用")
        }
        let coordinate: LocationCoordinate
        do {
            coordinate = try await location.currentLocation()
        } catch let error as LocationError {
            switch error {
            case .unauthorized:
                return .failure("location_denied", hint: "用户未授权定位，请建议用户到系统设置开启定位权限后重试，不要编造餐厅")
            case .timeout:
                return .failure("location_timeout", hint: "定位超时，请建议稍后再试，不要编造餐厅")
            case .unavailable:
                return .failure("location_unavailable", hint: "暂时拿不到当前位置，请如实告知，不要编造餐厅")
            }
        } catch {
            return .failure("location_unavailable", hint: "暂时拿不到当前位置，不要编造餐厅")
        }

        let trimmed = keywords?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effectiveKeywords = trimmed.isEmpty ? "美食" : trimmed
        let radius = min(max(radiusMeters ?? 1500, 100), 5000)
        let arguments = "{\"keywords\":\(encodeJSONString(effectiveKeywords)),\"location\":\(encodeJSONString(coordinate.amapLocationString)),\"radius\":\(radius)}"
        do {
            let text = try await client.callTool(name: "maps-around-search", argumentsJSON: arguments)
            let result = Self.parse(text: text)
            if result.error == nil && result.places.isEmpty {
                return .failure("empty", hint: "附近没有搜到相关餐厅，可建议换个关键词或扩大半径")
            }
            return result
        } catch let error as MCPCallError {
            return .failure("server_error", hint: error.localizedDescription)
        } catch {
            return .failure("network", hint: "附近搜索网络失败，请如实告知稍后再试，不要编造餐厅")
        }
    }

    private func encodeJSONString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        // [value] 序列化为 ["..."]，去掉首尾括号得到转义后的字符串字面量。
        return String(text.dropFirst().dropLast())
    }

    /// 解析 maps-around-search 返回文本：标准形态为 {"pois":[{id,name,type,address,location,distance}]}。
    static func parse(text: String, limit: Int = 8) -> NearbyFoodSearchResult {
        guard let object = LLMJSON.object(from: text) else {
            return .failure("server_error", hint: "高德返回内容无法解析")
        }
        if let status = object["status"] as? String, status != "1" {
            let info = (object["info"] as? String) ?? "高德服务异常"
            return .failure("server_error", hint: info)
        }
        let pois = (object["pois"] as? [[String: Any]]) ?? []
        var places: [NearbyPlace] = []
        for poi in pois {
            guard let id = poi["id"] as? String,
                  let name = poi["name"] as? String,
                  let locationText = poi["location"] as? String,
                  let coordinate = parseCoordinate(locationText) else { continue }
            let type = compactType(poi["type"] as? String)
            places.append(
                NearbyPlace(
                    id: id,
                    name: name,
                    type: type,
                    address: (poi["address"] as? String) ?? "",
                    distanceMeters: parseDistance(poi["distance"]),
                    longitude: coordinate.longitude,
                    latitude: coordinate.latitude
                )
            )
            if places.count >= limit { break }
        }
        if places.isEmpty {
            return .failure("empty", hint: "附近没有搜到相关餐厅，可建议换个关键词或扩大半径")
        }
        return NearbyFoodSearchResult(places: places, error: nil, hint: nil)
    }

    private static func parseCoordinate(_ text: String) -> LocationCoordinate? {
        let parts = text.split(separator: ",").map(String.init)
        guard parts.count >= 2,
              let longitude = Double(parts[0]),
              let latitude = Double(parts[1]) else { return nil }
        return LocationCoordinate(latitude: latitude, longitude: longitude)
    }

    private static func parseDistance(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) }
        return nil
    }

    /// 高德 type 形如 "餐饮服务;中餐厅;火锅店"，取最有辨识度的一段。
    private static func compactType(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "餐厅" }
        let parts = raw.split(separator: ";").map(String.init).filter { !$0.isEmpty }
        if parts.count >= 2 {
            return parts[1]
        }
        return parts.first ?? "餐厅"
    }
}

/// 离线演示 / UI 测试用：返回内置样例餐厅，不触网、不定位。
struct MockNearbyFoodService: NearbyFoodSearching {
    var isConfigured: Bool
    var error: String?

    init(isConfigured: Bool = true, error: String? = nil) {
        self.isConfigured = isConfigured
        self.error = error
    }

    func search(keywords: String?, radiusMeters: Int?) async -> NearbyFoodSearchResult {
        if let error {
            return .failure(error, hint: "演示错误路径：\(error)")
        }
        let filtered: [NearbyPlace]
        if let keywords, !keywords.isEmpty {
            filtered = Self.samplePlaces.filter { place in
                place.name.localizedCaseInsensitiveContains(keywords) || place.type.localizedCaseInsensitiveContains(keywords)
            }
        } else {
            filtered = Self.samplePlaces
        }
        if filtered.isEmpty {
            return NearbyFoodSearchResult(places: Self.samplePlaces, error: nil, hint: nil)
        }
        return NearbyFoodSearchResult(places: filtered, error: nil, hint: nil)
    }

    static let samplePlaces: [NearbyPlace] = [
        NearbyPlace(id: "mock-poi-1", name: "西贝莜面村（国贸店）", type: "中餐厅", address: "建国门外大街1号国贸商城B2层", distanceMeters: 320, longitude: 116.4571, latitude: 39.9087),
        NearbyPlace(id: "mock-poi-2", name: "庆丰包子铺（光辉里店）", type: "小吃快餐", address: "光辉里小区1号楼底商", distanceMeters: 150, longitude: 116.4529, latitude: 39.9126),
        NearbyPlace(id: "mock-poi-3", name: "沙县小吃（永安里店）", type: "小吃快餐", address: "建国门外大街12号", distanceMeters: 480, longitude: 116.4500, latitude: 39.9075),
        NearbyPlace(id: "mock-poi-4", name: "眉州东坡酒楼（大望路店）", type: "川菜", address: "西大望路15号", distanceMeters: 950, longitude: 116.4756, latitude: 39.9060),
    ]
}
