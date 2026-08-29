import Foundation
@testable import CareLoop
import Testing

/// 附近搜索工具接入云端 Agent 工具循环的行为测试：
/// 组合工具注入、POI 引用解析、校验放宽（食谱或 POI 至少其一）、降级与错误回填。
struct FakeNearbySearch: NearbyFoodSearching, Sendable {
    var configured: Bool = true
    var result: NearbyFoodSearchResult

    var isConfigured: Bool { configured }

    func search(keywords: String?, radiusMeters: Int?) async -> NearbyFoodSearchResult {
        result
    }
}

/// 复刻 ScriptedStreamLLMProvider 的回放逻辑，额外记录每轮请求（断言工具注入与消息回填）。
final class RecordingScriptedProvider: LLMProviding, @unchecked Sendable {
    var supportsVision: Bool { false }
    var supportsToolCall: Bool { true }

    private let rounds: [[LLMStreamEvent]]
    private var round = 0
    private let lock = NSLock()
    private(set) var requests: [LLMConversationRequest] = []

    init(rounds: [[LLMStreamEvent]]) {
        self.rounds = rounds
    }

    func complete(prompt: LLMPrompt) async throws -> LLMCompletion {
        LLMCompletion(text: "", modelID: "scripted")
    }

    func completeConversation(_ request: LLMConversationRequest) async throws -> LLMConversationResponse {
        LLMConversationResponse(
            message: LLMChatMessage(role: "assistant", content: "", toolCallID: nil, toolCalls: []),
            modelID: "scripted",
            finishReason: "stop"
        )
    }

    func streamConversation(_ request: LLMConversationRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        lock.lock()
        requests.append(request)
        let events = rounds[min(round, rounds.count - 1)]
        round += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            let task = Task {
                for event in events {
                    if Task.isCancelled { break }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels() async throws -> [String] { ["scripted"] }
    func ping(modelID: String) async throws -> TimeInterval { 0.01 }
}

struct NearbyFoodAgentLoopTests {
    private var heartProfile: ProfileTags {
        ProfileTags(
            conditions: ["高血压"],
            foodAllergies: [],
            injuries: [],
            doctorRestrictions: [],
            cuisineLikes: ["粤菜"],
            cuisineDislikes: [],
            spiciness: "none",
            dislikedIngredients: [],
            dietGoals: ["控盐"],
            preferredSports: [],
            avoidedSports: [],
            facilities: [],
            intensityCeiling: "低",
            region: "广东",
            ageDecade: "60s"
        )
    }

    private func makeContext() -> DietAgentContext {
        DietAgentContext(
            profile: heartProfile,
            trendSummary: "",
            todayStatus: "",
            recipes: ContentLibrary.loadRecipes(),
            dietRules: DietGuidelineRules.load(),
            guardrailRules: GuidelineRules.load()
        )
    }

    private static let places = [
        NearbyPlace(id: "poi-1", name: "西贝莜面村", type: "中餐厅", address: "建国门外大街1号", distanceMeters: 320, longitude: 116.4571, latitude: 39.9087),
        NearbyPlace(id: "poi-2", name: "庆丰包子铺", type: "小吃快餐", address: "光辉里1号楼", distanceMeters: 150, longitude: 116.4529, latitude: 39.9126),
    ]

    private static func nearbyResult() -> NearbyFoodSearchResult {
        NearbyFoodSearchResult(places: places, error: nil, hint: nil)
    }

    private static func toolRound() -> [LLMStreamEvent] {
        let call = LLMToolCall(id: "c-nearby", name: "search_nearby_food", argumentsJSON: #"{"keywords":"清淡"}"#)
        return [
            .toolCalls([call]),
            .finished(
                LLMConversationResponse(
                    message: LLMChatMessage(role: "assistant", content: nil, toolCallID: nil, toolCalls: [call]),
                    modelID: "scripted",
                    finishReason: "tool_calls"
                )
            ),
        ]
    }

    private static func textRound(_ json: String) -> [LLMStreamEvent] {
        [
            .textDelta(json),
            .finished(
                LLMConversationResponse(
                    message: LLMChatMessage(role: "assistant", content: json, toolCallID: nil, toolCalls: []),
                    modelID: "scripted",
                    finishReason: "stop"
                )
            ),
        ]
    }

    /// 附近工具轮 → 引用 POI 的最终轮：进度标签、citedPOIs 解析、
    /// 「食谱与 POI 至少引用其一」的放宽规则（本例食谱引用为空）。
    @Test func nearbyToolRoundResolvesPOIsWithoutRecipeCitation() async throws {
        let context = makeContext()
        let reply = "附近有两家合适：西贝莜面村约320米，庆丰包子铺约150米，控盐优选蒸煮类。"
        let finalJSON = #"{"reply":"\#(reply)","citedRecipeIDs":[],"citedClauseIDs":[],"citedPOIIDs":["poi-1","poi-2"]}"#
        let provider = RecordingScriptedProvider(rounds: [Self.toolRound(), Self.textRound(finalJSON)])
        let nearby = FakeNearbySearch(result: Self.nearbyResult())

        var events: [DietAgentEvent] = []
        for try await event in CloudDietAgentEngine.stream(
            to: "附近有什么能吃的", context: context, llm: provider, nearby: nearby
        ) {
            events.append(event)
        }

        guard case .toolStarted(let name, let label)? = events.first else {
            Issue.record("首个事件应为 toolStarted，实际：\(events)")
            return
        }
        #expect(name == "search_nearby_food")
        #expect(label == "搜索附近餐厅")
        #expect(events.contains { event in
            if case .toolFinished("search_nearby_food") = event { return true }
            return false
        })

        guard case .finished(let response)? = events.last else {
            Issue.record("应以 finished 收尾，实际：\(events)")
            return
        }
        #expect(!response.degraded)
        #expect(response.usedLLM)
        #expect(response.citedPOIs.map(\.id) == ["poi-1", "poi-2"])
        #expect(response.citedPOIs.first?.navigationURL.absoluteString.contains("uri.amap.com/navigation") == true)

        // 第二轮请求里应包含工具结果消息（模型据此作答）。
        let secondRequest = provider.requests.last
        #expect(secondRequest?.messages.contains { message in
            message.role == "tool" && (message.content ?? "").contains("poi-1")
        } == true)
    }

    /// 引用了工具没返回过的 POI id → 校验失败 → 降级本地模板。
    @Test func unknownPOIIDFallsBackToDegraded() async throws {
        let context = makeContext()
        let finalJSON = #"{"reply":"附近推荐 XX 家","citedRecipeIDs":[],"citedClauseIDs":[],"citedPOIIDs":["poi-ghost"]}"#
        let provider = RecordingScriptedProvider(rounds: [Self.toolRound(), Self.textRound(finalJSON)])
        let nearby = FakeNearbySearch(result: Self.nearbyResult())

        var final: DietAgentResponse?
        for try await event in CloudDietAgentEngine.stream(
            to: "附近吃什么", context: context, llm: provider, nearby: nearby
        ) {
            if case .finished(let response) = event { final = response }
        }
        let response = try #require(final)
        #expect(response.degraded)
        #expect(response.citedPOIs.isEmpty)
    }

    /// POI 引用合法但触发黑名单词 → 仍然拦截（护栏不因 POI 路径放松）。
    @Test func blacklistStillEnforcedWithPOICitation() async throws {
        let context = makeContext()
        let finalJSON = #"{"reply":"附近可以吃，建议停药后再去","citedRecipeIDs":[],"citedClauseIDs":[],"citedPOIIDs":["poi-1"]}"#
        let provider = RecordingScriptedProvider(rounds: [Self.toolRound(), Self.textRound(finalJSON)])
        let nearby = FakeNearbySearch(result: Self.nearbyResult())

        var final: DietAgentResponse?
        for try await event in CloudDietAgentEngine.stream(
            to: "附近吃什么", context: context, llm: provider, nearby: nearby
        ) {
            if case .finished(let response) = event { final = response }
        }
        let response = try #require(final)
        #expect(response.degraded)
        #expect(!response.usedLLM)
    }

    /// 服务未配置时不注入附近工具定义，system prompt 也不含附近条款。
    @Test func unconfiguredNearbyOmitsToolDefinition() async throws {
        let context = makeContext()
        let safeID = DietTools.filterSafeRecipes(
            context.recipes, profile: heartProfile, dietRules: context.dietRules
        ).first?.id ?? "recipe-001"
        let finalJSON = #"{"reply":"清淡为主","citedRecipeIDs":["\#(safeID)"],"citedClauseIDs":[]}"#
        let provider = RecordingScriptedProvider(rounds: [Self.textRound(finalJSON)])
        let nearby = FakeNearbySearch(configured: false, result: Self.nearbyResult())

        var final: DietAgentResponse?
        for try await event in CloudDietAgentEngine.stream(
            to: "吃什么", context: context, llm: provider, nearby: nearby
        ) {
            if case .finished(let response) = event { final = response }
        }
        let request = provider.requests.first
        #expect(request?.tools.contains { $0.name == "search_nearby_food" } == false)
        #expect(request?.system == CloudDietAgentEngine.systemPrompt)
        let response = try #require(final)
        #expect(!response.degraded)
    }

    /// 定位被拒：工具结果回填 error JSON，模型走常规引用食谱路径作答，循环不中断。
    @Test func locationDeniedErrorFeedsToolMessage() async throws {
        let context = makeContext()
        let safeID = DietTools.filterSafeRecipes(
            context.recipes, profile: heartProfile, dietRules: context.dietRules
        ).first?.id ?? "recipe-001"
        let finalJSON = #"{"reply":"定位没开呀，开一下权限再帮你找附近。今晚先看看家里的清淡搭配吧。","citedRecipeIDs":["\#(safeID)"],"citedClauseIDs":[]}"#
        let provider = RecordingScriptedProvider(rounds: [Self.toolRound(), Self.textRound(finalJSON)])
        let nearby = FakeNearbySearch(
            result: .failure("location_denied", hint: "建议用户开启定位权限")
        )

        var events: [DietAgentEvent] = []
        for try await event in CloudDietAgentEngine.stream(
            to: "附近有什么吃的", context: context, llm: provider, nearby: nearby
        ) {
            events.append(event)
        }

        let secondRequest = provider.requests.last
        let toolMessage = secondRequest?.messages.first { $0.role == "tool" }
        #expect(toolMessage?.content?.contains("location_denied") == true, "定位错误应回填给模型")

        guard case .finished(let response)? = events.last else {
            Issue.record("应以 finished 收尾，实际：\(events)")
            return
        }
        #expect(!response.degraded)
    }

    /// MockLLMProvider（UI 测试同款）+ MockNearbyFoodService 的离线全链路：
    /// 触发 search_nearby_food 工具轮 → 引用 mock POI 通过校验。
    @Test func mockProviderNearbyLoop() async throws {
        let context = makeContext()
        var events: [DietAgentEvent] = []
        for try await event in CloudDietAgentEngine.stream(
            to: "附近有什么能吃的",
            context: context,
            llm: MockLLMProvider(),
            nearby: MockNearbyFoodService()
        ) {
            events.append(event)
        }
        guard case .finished(let response)? = events.last else {
            Issue.record("应以 finished 收尾，实际：\(events)")
            return
        }
        #expect(!response.degraded, "Mock 全链路应通过校验：\(response.reply)")
        #expect(response.citedPOIs.map(\.id) == ["mock-poi-1", "mock-poi-2"])
        #expect(response.citedPOIs.first?.distanceText == "320 m")
    }

    // MARK: - 解析与模型视图

    /// 高德原始 POI 格式解析：type 分号段、distance 字符串、location 逗号串。
    @Test func parseAmapPOIFields() throws {
        let text = """
        {"status":"1","pois":[{"id":"B1","name":"粥店","type":"餐饮服务;中餐厅;粥店","address":"中山路2号","location":"116.30,39.90","distance":"1024"}]}
        """
        let result = NearbyFoodService.parse(text: text)
        #expect(result.error == nil)
        let place = try #require(result.places.first)
        #expect(place.type == "中餐厅")
        #expect(place.distanceMeters == 1024)
        #expect(place.distanceText == "1.0 km")
        #expect(abs(place.longitude - 116.30) < 0.000001)
        #expect(abs(place.latitude - 39.90) < 0.000001)
    }

    /// status!=1（如配额超限）映射为 server_error。
    @Test func parseAmapErrorStatus() {
        let result = NearbyFoodService.parse(text: #"{"status":"0","info":"DAILY_QUERY_OVER_LIMIT"}"#)
        #expect(result.error == "server_error")
        #expect(result.places.isEmpty)
    }

    /// 模型视图只含 id/名称/类型/地址/距离，经纬度绝不外发。
    @Test func modelPayloadNeverContainsCoordinates() {
        let payload = NearbyFoodJSON.modelPayload(Self.nearbyResult())
        #expect(!payload.contains("116.4571"))
        #expect(!payload.contains("39.9087"))
        #expect(payload.contains("poi-1"))
        #expect(payload.contains("distance_m"))
    }
}
