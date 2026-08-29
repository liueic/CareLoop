import Foundation
@testable import CareLoop
import Testing

/// 脚本化流式 Provider：按轮次回放事件序列，驱动云端 Agent 的流式循环。
final class ScriptedStreamLLMProvider: LLMProviding, @unchecked Sendable {
    enum Tail {
        case finish
        case hang
    }

    var supportsVision: Bool { false }
    var supportsToolCall: Bool { true }

    private let rounds: [[LLMStreamEvent]]
    private let tail: Tail
    private var round = 0

    init(rounds: [[LLMStreamEvent]], tail: Tail = .finish) {
        self.rounds = rounds
        self.tail = tail
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
        let events = rounds[min(round, rounds.count - 1)]
        round += 1
        return AsyncThrowingStream { continuation in
            let task = Task {
                for event in events {
                    if Task.isCancelled { break }
                    continuation.yield(event)
                }
                switch tail {
                case .finish:
                    continuation.finish()
                case .hang:
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    continuation.finish(throwing: CancellationError())
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels() async throws -> [String] { ["scripted"] }
    func ping(modelID: String) async throws -> TimeInterval { 0.01 }
}

struct DietAgentStreamingTests {
    private var heartProfile: ProfileTags {
        ProfileTags(
            conditions: ["心脏病", "高血压"],
            foodAllergies: ["虾"],
            injuries: [],
            doctorRestrictions: [],
            cuisineLikes: ["粤菜"],
            cuisineDislikes: [],
            spiciness: "none",
            dislikedIngredients: ["香菜"],
            dietGoals: ["控盐"],
            preferredSports: ["快走"],
            avoidedSports: ["HIIT"],
            facilities: ["室内", "户外"],
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

    /// 工具轮 + 最终 JSON 分片流：事件顺序、文本重组、引用校验全部成立。
    @Test func toolRoundThenStreamedReply() async throws {
        let context = makeContext()
        let safeID = DietTools.filterSafeRecipes(
            context.recipes, profile: heartProfile, dietRules: context.dietRules
        ).first?.id ?? "recipe-001"

        let replyText = "今晚可以试试清蒸鲈鱼，少盐少油，份量适中。"
        let finalJSON = #"{"reply":"\#(replyText)","citedRecipeIDs":["\#(safeID)"],"citedClauseIDs":[]}"#
        let toolCall = LLMToolCall(id: "c1", name: "filter_safe_recipes", argumentsJSON: #"{"limit":2}"#)

        let provider = ScriptedStreamLLMProvider(rounds: [
            [
                .toolCalls([toolCall]),
                .finished(
                    LLMConversationResponse(
                        message: LLMChatMessage(role: "assistant", content: nil, toolCallID: nil, toolCalls: [toolCall]),
                        modelID: "scripted",
                        finishReason: "tool_calls"
                    )
                ),
            ],
            [
                .textDelta(String(finalJSON.prefix(9))),
                .textDelta(String(finalJSON.dropFirst(9).prefix(14))),
                .textDelta(String(finalJSON.dropFirst(23))),
                .finished(
                    LLMConversationResponse(
                        message: LLMChatMessage(role: "assistant", content: finalJSON, toolCallID: nil, toolCalls: []),
                        modelID: "scripted",
                        finishReason: "stop"
                    )
                ),
            ],
        ])

        var events: [DietAgentEvent] = []
        for try await event in CloudDietAgentEngine.stream(to: "今晚吃什么", context: context, llm: provider) {
            events.append(event)
        }

        // 工具进度先于回复文本。
        guard case .toolStarted(let startedName, let startedLabel) = events.first else {
            Issue.record("首个事件应为 toolStarted，实际：\(events)")
            return
        }
        #expect(startedName == "filter_safe_recipes")
        #expect(startedLabel == "筛选安全食谱")
        #expect(events.contains { event in
            if case .toolFinished(let name) = event { return name == "filter_safe_recipes" }
            return false
        })

        // 流式文本重组后应等于完整 reply（JSON 壳被剥掉）。
        let streamed = events.compactMap { event -> String? in
            if case .replyDelta(let delta) = event { return delta }
            return nil
        }.joined()
        #expect(streamed == replyText)

        // 最终结果通过校验、未降级、引用正确。
        guard case .finished(let response) = events.last else {
            Issue.record("末个事件应为 finished，实际：\(events)")
            return
        }
        #expect(response.usedLLM)
        #expect(!response.degraded)
        #expect(response.citedRecipeIDs == [safeID])
        #expect(response.reply == replyText)
    }

    /// 校验失败（触发黑名单词）时降级到本地模板。
    @Test func guardrailViolationDegradesToFallback() async throws {
        let context = makeContext()
        let badJSON = #"{"reply":"建议停药后观察","citedRecipeIDs":[],"citedClauseIDs":[]}"#
        let provider = ScriptedStreamLLMProvider(rounds: [
            [
                .textDelta(badJSON),
                .finished(
                    LLMConversationResponse(
                        message: LLMChatMessage(role: "assistant", content: badJSON, toolCallID: nil, toolCalls: []),
                        modelID: "scripted",
                        finishReason: "stop"
                    )
                ),
            ],
        ])

        var final: DietAgentResponse?
        for try await event in CloudDietAgentEngine.stream(to: "随便问点啥", context: context, llm: provider) {
            if case .finished(let response) = event { final = response }
        }
        let response = try #require(final)
        #expect(response.degraded)
        #expect(!response.usedLLM)
    }

    /// 外层取消后不应再产出 finished 降级事件（AsyncThrowingStream 取消时常以正常结束收尾）。
    @Test func cancellationStopsWithoutFallback() async throws {
        let context = makeContext()
        let provider = ScriptedStreamLLMProvider(rounds: [[.textDelta(#"{"reply":"正在慢慢"#)]], tail: .hang)
        let stream = CloudDietAgentEngine.stream(to: "慢慢想", context: context, llm: provider)

        let consumer = Task<[DietAgentEvent], Error> {
            var collected: [DietAgentEvent] = []
            for try await event in stream {
                collected.append(event)
            }
            return collected
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        consumer.cancel()
        let events = try await consumer.value
        #expect(!events.contains { event in
            if case .finished = event { return true }
            return false
        }, "取消后不应吐出 finished（降级或最终）事件")
    }

    /// 阻塞版 respond 与流式版共享同一循环，结果一致。
    @Test func blockingRespondMatchesStream() async throws {
        let context = makeContext()
        let safeID = DietTools.filterSafeRecipes(
            context.recipes, profile: heartProfile, dietRules: context.dietRules
        ).first?.id ?? "recipe-001"
        let finalJSON = #"{"reply":"清淡为主","citedRecipeIDs":["\#(safeID)"],"citedClauseIDs":[]}"#
        let provider = ScriptedStreamLLMProvider(rounds: [
            [
                .textDelta(finalJSON),
                .finished(
                    LLMConversationResponse(
                        message: LLMChatMessage(role: "assistant", content: finalJSON, toolCallID: nil, toolCalls: []),
                        modelID: "scripted",
                        finishReason: "stop"
                    )
                ),
            ],
        ])
        let response = try await CloudDietAgentEngine.respond(to: "吃什么", context: context, llm: provider)
        #expect(response.reply == "清淡为主")
        #expect(!response.degraded)
    }

    /// 用真实 MockLLMProvider（UI 测试同款）驱动完整工具循环，隔离 UI 层问题。
    @Test func mockProviderDrivesFullToolLoop() async throws {
        let context = makeContext()
        var events: [DietAgentEvent] = []
        for try await event in CloudDietAgentEngine.stream(to: "今晚吃什么好", context: context, llm: MockLLMProvider()) {
            events.append(event)
        }
        let toolStarts = events.filter {
            if case .toolStarted = $0 { return true }
            return false
        }
        #expect(!toolStarts.isEmpty, "Mock 应触发工具轮，事件：\(events)")
        guard case .finished(let response)? = events.last else {
            Issue.record("应以 finished 收尾，事件：\(events)")
            return
        }
        #expect(!response.degraded, "校验应通过而非降级：\(response.reply)")
        #expect(response.reply.contains("清淡"))
    }

    /// 回归：Mock 第二轮（工具结果回传后）应返回带引用的饮食 JSON 并通过校验。
    /// 曾经因分派顺序 bug 返回食物识别 JSON 导致必然降级。
    @Test func mockRoundTwoPassesValidation() async throws {
        let context = makeContext()
        let safeRecipes = DietTools.filterSafeRecipes(context.recipes, profile: heartProfile, dietRules: context.dietRules)
        let allowed = Set(safeRecipes.map(\.id))
        let allowedClauses = Set(context.dietRules.clauses.map(\.id))

        let toolCalls = [
            LLMToolCall(id: "call_1", name: "get_profile_and_status", argumentsJSON: "{}"),
            LLMToolCall(id: "call_2", name: "filter_safe_recipes", argumentsJSON: #"{"limit":8}"#),
        ]
        let request = LLMConversationRequest(
            system: CloudDietAgentEngine.systemPrompt,
            messages: [
                LLMChatMessage(role: "user", content: "今晚吃什么好", toolCallID: nil, toolCalls: []),
                LLMChatMessage(role: "assistant", content: nil, toolCallID: nil, toolCalls: toolCalls),
                LLMChatMessage(role: "tool", content: DietTools.profileAndStatusJSON(context: context), toolCallID: "call_1", toolCalls: []),
                LLMChatMessage(role: "tool", content: DietTools.recipesJSON(safeRecipes, limit: 8), toolCallID: "call_2", toolCalls: []),
            ],
            tools: [],
            maxTokens: 700
        )
        var content = ""
        for try await event in MockLLMProvider().streamConversation(request) {
            if case .finished(let r) = event { content = r.message.content ?? "" }
        }
        let parsed = DietTools.parseAgentJSON(content)
        #expect(parsed.recipeIDs.count == 1, "第二轮应引用安全食谱：\(content)")
        #expect(DietTools.validateAgentReply(
            text: parsed.reply,
            citedRecipeIDs: parsed.recipeIDs,
            citedClauseIDs: parsed.clauseIDs,
            allowedRecipeIDs: allowed,
            allowedClauseIDs: allowedClauses,
            guardrailRules: context.guardrailRules
        ), "第二轮内容应通过校验：\(content)")
    }
}
