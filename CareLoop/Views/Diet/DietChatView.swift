import SwiftData
import SwiftUI
import CoreSpotlight

/// 饱饱 · 饮食陪伴对话页。
struct DietChatView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var messages: [BaobaoMessage] = []
    @State private var phase: AgentPhase = .idle
    @State private var toolProgress: [ToolProgressItem] = []
    @State private var streamingText = ""
    @State private var sendTask: Task<Void, Never>?
    @State private var selection: BaobaoSelection?
    @State private var showClearConfirm = false
    @State private var trendSummary = ""
    @State private var recentGlucose: String?
    @State private var recentBloodPressure: String?
    @State private var retainedAgent: (any DietAgentSession)?
    @State private var retainedNearbyAgent: (any DietAgentSession)?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                selectionBanner
                conversation
                Divider()
                suggestionArea
                inputBar
            }
            .background(CareTheme.paper.ignoresSafeArea())
            .navigationTitle(BaobaoPersona.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .foregroundStyle(CareTheme.ink)
                    }
                    .accessibilityLabel("返回")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("清空对话", role: .destructive) { showClearConfirm = true }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(CareTheme.ink)
                    }
                }
            }
            .confirmationDialog("清空这段对话？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空", role: .destructive) {
                    messages = [BaobaoMessage(role: .baobao, text: BaobaoPersona.greeting)]
                }
                Button("取消", role: .cancel) {}
            }
            .task {
                selection = BaobaoState.selection()
                if messages.isEmpty {
                    messages = [BaobaoMessage(role: .baobao, text: BaobaoPersona.greeting)]
                }
                await prepareSession()
            }
            .onDisappear {
                sendTask?.cancel()
            }
        }
    }

    // MARK: 顶部已选横幅

    @ViewBuilder
    private var selectionBanner: some View {
        if let selection {
            HStack(spacing: 6) {
                Text("今日已选：\(selection.recipeName)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(CareTheme.sage)
                Button {
                    BaobaoState.clear()
                    self.selection = nil
                    messages.append(BaobaoMessage(role: .baobao, text: BaobaoPersona.undoReply))
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(CareTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("撤销今日已选")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(CareTheme.sageSoft))
            .padding(.top, 8)
        }
    }

    // MARK: 对话流

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(messages) { message in
                        bubble(for: message)
                            .id(message.id)
                    }
                    if phase != .idle {
                        AgentProgressBubble(phase: phase, tools: toolProgress, streamingText: streamingText)
                            .id("progress")
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: phase) { _, _ in scrollToBottom(proxy) }
            .onChange(of: streamingText) { _, _ in scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation {
            if phase != .idle {
                proxy.scrollTo("progress", anchor: .bottom)
            } else if let id = messages.last?.id {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func bubble(for message: BaobaoMessage) -> some View {
        switch message.role {
        case .user:
            Text(message.text)
                .font(CareTheme.body)
                .foregroundStyle(CareTheme.ink)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(CareTheme.sageSoft)
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .baobao:
            VStack(alignment: .leading, spacing: 8) {
                if message.isError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(CareTheme.muted)
                        Text(message.text)
                            .font(CareTheme.body)
                            .foregroundStyle(CareTheme.muted)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(white: 0.96))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(CareTheme.muted.opacity(0.3), lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if message.isConfirmation {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message.text)
                            .font(CareTheme.body)
                            .foregroundStyle(CareTheme.ink)
                        Label("已记录到今日推荐", systemImage: "checkmark")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(CareTheme.sage)
                        Button {
                            dismiss()
                        } label: {
                            Text("返回首页看看 →")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(CareTheme.sage)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white)
                            .shadow(color: CareTheme.ink.opacity(0.05), radius: 4, y: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(CareTheme.sage.opacity(0.5), lineWidth: 1)
                    )
                } else {
                    Text(message.text)
                        .font(CareTheme.body)
                        .foregroundStyle(CareTheme.ink)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.white)
                                .shadow(color: CareTheme.ink.opacity(0.05), radius: 4, y: 1)
                        )
                    if let pois = message.suggestedPOIs, !pois.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(pois) { place in
                                NearbyPlaceCard(place: place)
                            }
                        }
                        .accessibilityIdentifier("careloop.diet.poiCards")
                    }
                    if let recipes = message.suggestedRecipes, !recipes.isEmpty, selection == nil {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                ForEach(recipes.prefix(2)) { recipe in
                                    Button {
                                        confirm(recipe)
                                    } label: {
                                        Text(recipe.name)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(CareTheme.sage)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 7)
                                            .background(
                                                Capsule()
                                                    .fill(.white)
                                                    .overlay(Capsule().stroke(CareTheme.sage.opacity(0.5), lineWidth: 1))
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            Button {
                                input = "都不想吃"
                                Task { await send() }
                            } label: {
                                Text("都不想吃…")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(CareTheme.muted)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule()
                                            .fill(Color(white: 0.96))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 底部推荐词条

    @ViewBuilder
    private var suggestionArea: some View {
        if messages.count <= 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("猜你现在想问：")
                    .font(.caption)
                    .foregroundStyle(CareTheme.muted)
                HStack(spacing: 8) {
                    ForEach(BaobaoPersona.quickReplies, id: \.self) { text in
                        Button {
                            input = text
                            Task { await send() }
                        } label: {
                            Text(text)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(CareTheme.sage)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule()
                                        .fill(.white)
                                        .overlay(Capsule().stroke(CareTheme.sage.opacity(0.35), lineWidth: 1))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 10)
        }
    }

    // MARK: 输入区

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("告诉饱饱你想吃什么...", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .font(CareTheme.body)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(CareTheme.track)
                        .frame(height: 1)
                }
                .accessibilityIdentifier("careloop.diet.input")
            if phase == .idle {
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(CareTheme.sage))
                }
                .buttonStyle(.plain)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("发送")
                .accessibilityIdentifier("careloop.diet.send")
            } else {
                Button {
                    sendTask?.cancel()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title3)
                        .foregroundStyle(CareTheme.muted)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("停止生成")
                .accessibilityIdentifier("careloop.diet.stop")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.white)
    }

    // MARK: 发送与确认

    private func send() async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, phase == .idle else { return }
        input = ""
        messages.append(BaobaoMessage(role: .user, text: trimmed))

        let profile = env.profile()
        let tags = profile.desensitizedTags()
        let safeRecipes = AdviceEngine.hardFilterRecipes(env.recipes, profile: tags, dietRules: env.dietRules)

        // 关键词快捷分支（确认/全部拒绝/拒绝食材）保持同步直出。
        if let quick = quickReply(to: trimmed, safeRecipes: safeRecipes) {
            messages.append(quick)
            return
        }

        let task = Task {
            await runAgentStream(
                to: trimmed,
                tags: tags,
                safeRecipes: safeRecipes,
                isNearby: NearbyIntentDetector.isNearbyIntent(trimmed)
            )
        }
        sendTask = task
        await task.value
        sendTask = nil
    }

    private func confirm(_ recipe: Recipe) {
        BaobaoState.confirm(recipeID: recipe.id, recipeName: recipe.name)
        selection = BaobaoState.selection()
        messages.append(
            BaobaoMessage(
                role: .baobao,
                text: BaobaoPersona.confirmReply(for: recipe.name),
                isConfirmation: true
            )
        )
    }

    /// 关键词快捷回复；命中返回消息，未命中返回 nil 走流式 Agent。
    private func quickReply(to text: String, safeRecipes: [Recipe]) -> BaobaoMessage? {
        // 确认场景：用户说"就这个吧"
        if BaobaoPersona.confirmWords.contains(where: { text.contains($0) }) {
            let lastSuggested = messages.last(where: { $0.suggestedRecipes?.isEmpty == false })?.suggestedRecipes
            let target = BaobaoPersona.mentionedRecipe(in: text, from: safeRecipes)
                ?? lastSuggested?.first
            if let target {
                return BaobaoMessage(
                    role: .baobao,
                    text: "那就 \(target.name) 啦！点下面告诉我哦 (=^･^=)",
                    suggestedRecipes: [target]
                )
            }
        }

        // 全部拒绝场景：用户说"都不想吃"
        if text.contains("都不想吃") {
            let lastSuggested = messages.last(where: { $0.suggestedRecipes?.isEmpty == false })?.suggestedRecipes ?? []
            let alternatives = safeRecipes.filter { recipe in
                !lastSuggested.contains(where: { $0.id == recipe.id })
            }
            let picks = Array((alternatives.isEmpty ? safeRecipes : alternatives).prefix(2))
            return BaobaoMessage(
                role: .baobao,
                text: BaobaoPersona.alternativesReply(for: picks.map(\.name)),
                suggestedRecipes: picks
            )
        }

        // 拒绝场景：用户说"不想吃 XX"
        if let rejected = BaobaoPersona.rejectedIngredient(in: text, from: safeRecipes) {
            let alternatives = safeRecipes.filter { recipe in
                !recipe.name.contains(rejected) && !recipe.ingredients.contains(rejected)
            }
            let picks = Array(alternatives.prefix(2))
            return BaobaoMessage(
                role: .baobao,
                text: BaobaoPersona.alternativesReply(for: picks.map(\.name)),
                suggestedRecipes: picks
            )
        }
        return nil
    }

    /// 一般提问：走流式饮食助手，边生成边上屏。
    /// isNearby：附近意图固定走云端 Agent（search_nearby_food 工具只在云端工具循环挂载）。
    private func runAgentStream(to text: String, tags: ProfileTags, safeRecipes: [Recipe], isNearby: Bool = false) async {
        let alerts = (try? env.context.fetch(FetchDescriptor<AlertRecord>())) ?? []
        let logs = (try? env.context.fetch(FetchDescriptor<DailyLogEntry>())) ?? []
        let profile = env.profile()
        let context = DietAgentContext(
            profile: tags,
            trendSummary: trendSummary,
            todayStatus: TodayStatus.from(alerts: alerts.filter { Calendar.current.isDateInToday($0.createdAt) }).rawValue,
            recipes: env.recipes,
            dietRules: env.dietRules,
            guardrailRules: env.rules,
            history: messages.suffix(6).map { ($0.role == .user ? "user" : "assistant", $0.text) },
            recentDietLogSummary: DietTools.dietLogSummary(entries: logs),
            recentGlucose: recentGlucose,
            recentBloodPressure: recentBloodPressure,
            currentMedicationNames: profile.currentMedicationNames
        )
        let agent: any DietAgentSession
        if isNearby {
            if let cached = retainedNearbyAgent {
                agent = cached
            } else {
                agent = DietAgentFactory.make(llm: env.currentLLM(), nearby: env.nearbyFoodService, preferOnDevice: false)
                retainedNearbyAgent = agent
            }
        } else {
            agent = retainedAgent ?? DietAgentFactory.make(llm: env.currentLLM())
            retainedAgent = agent
        }

        phase = .thinking
        toolProgress = []
        streamingText = ""
        defer {
            phase = .idle
            toolProgress = []
            streamingText = ""
        }

        do {
            var gotFinal = false
            for try await event in agent.streamRespond(to: text, context: context) {
                switch event {
                case .toolStarted(let name, let label):
                    // 工具轮开始时清掉模型先吐的草稿文本，正式答案稍后重新流式上屏。
                    streamingText = ""
                    phase = .thinking
                    if let index = toolProgress.firstIndex(where: { $0.name == name }) {
                        toolProgress[index].isDone = false
                    } else {
                        toolProgress.append(ToolProgressItem(name: name, label: label))
                    }
                case .toolFinished(let name):
                    if let index = toolProgress.firstIndex(where: { $0.name == name }) {
                        toolProgress[index].isDone = true
                    }
                case .replyDelta(let delta):
                    phase = .streaming
                    streamingText += delta
                case .finished(let response):
                    gotFinal = true
                    let cited = safeRecipes.filter { response.citedRecipeIDs.contains($0.id) }
                    messages.append(
                        BaobaoMessage(
                            role: .baobao,
                            text: response.reply,
                            suggestedRecipes: Array(cited.prefix(2)),
                            suggestedPOIs: response.citedPOIs.isEmpty ? nil : response.citedPOIs
                        )
                    )
                }
            }
            // AsyncThrowingStream 取消时常以正常结束收尾而非抛错：
            // 有部分文本且没等到最终结果时，按“已停止生成”保留。
            if Task.isCancelled, !gotFinal, !streamingText.isEmpty {
                messages.append(BaobaoMessage(role: .baobao, text: streamingText + "\n（已停止生成）", isInterrupted: true))
            }
        } catch is CancellationError {
            if !streamingText.isEmpty {
                messages.append(BaobaoMessage(role: .baobao, text: streamingText + "\n（已停止生成）", isInterrupted: true))
            }
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if !streamingText.isEmpty {
                messages.append(
                    BaobaoMessage(role: .baobao, text: streamingText + "\n（回复中断：\(detail)）", isInterrupted: true)
                )
            } else {
                messages.append(BaobaoMessage(role: .baobao, text: "网络似乎不太顺畅（\(detail)），稍后再试一次吧。", isError: true))
            }
        }
    }

    private func prepareSession() async {
        if #available(iOS 18.0, *) {
            CSUserQuery.prepare()
        }
        if retainedAgent == nil {
            retainedAgent = DietAgentFactory.make(llm: env.currentLLM())
        }
        await loadPersonalContext()
    }

    private func loadPersonalContext() async {
        let types: [MetricType] = [.sleepHours, .restingHeartRate, .stepCount]
        var parts: [String] = []
        for type in types {
            let series = await env.healthProvider.dailySeries(type, days: 7)
            let result = BaselineEngine.evaluate(type: type, series: series)
            parts.append("\(type.displayName) z=\(result.zScore.map { String(format: "%.1f", $0) } ?? "n/a")")
        }
        trendSummary = parts.joined(separator: "，")
        let snapshot = await env.healthProvider.watermarkSnapshot(at: Date())
        recentGlucose = DietTools.metricSummary(
            label: "血糖",
            value: snapshot.bloodGlucose,
            unit: "mmol/L",
            source: snapshot.sourceName
        )
        recentBloodPressure = DietTools.bloodPressureSummary(
            systolic: snapshot.bloodPressureSystolic,
            diastolic: snapshot.bloodPressureDiastolic,
            source: snapshot.sourceName
        )
    }
}

// MARK: - 消息模型

struct BaobaoMessage: Identifiable {
    enum Role {
        case user
        case baobao
    }

    var id = UUID()
    var role: Role
    var text: String
    var suggestedRecipes: [Recipe]? = nil
    var suggestedPOIs: [NearbyPlace]? = nil
    var isConfirmation = false
    var isError = false
    var isInterrupted = false
}

// MARK: - 生成阶段与工具进度

enum AgentPhase: Equatable {
    case idle
    case thinking
    case streaming
}

struct ToolProgressItem: Identifiable, Equatable {
    let name: String
    let label: String
    var isDone = false
    var id: String { name }
}

/// 生成中的进度气泡：工具调用 chip（进行中/已完成）+ 流式文本。
struct AgentProgressBubble: View {
    let phase: AgentPhase
    let tools: [ToolProgressItem]
    let streamingText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tools.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(tools) { tool in
                        HStack(spacing: 6) {
                            if tool.isDone {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(CareTheme.sage)
                            } else {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                            Text(tool.label)
                                .font(.caption)
                                .foregroundStyle(tool.isDone ? CareTheme.muted : CareTheme.ink)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(Color(white: 0.965))
                        )
                    }
                }
                .accessibilityIdentifier("careloop.diet.toolstatus")
            }
            if !streamingText.isEmpty {
                HStack(alignment: .bottom, spacing: 2) {
                    Text(streamingText)
                        .font(CareTheme.body)
                        .foregroundStyle(CareTheme.ink)
                    // 光标：流式进行中的视觉信号。
                    RoundedRectangle(cornerRadius: 1)
                        .fill(CareTheme.sage)
                        .frame(width: 2, height: 16)
                        .opacity(phase == .streaming ? 1 : 0)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white)
                        .shadow(color: CareTheme.ink.opacity(0.05), radius: 4, y: 1)
                )
                .accessibilityIdentifier("careloop.diet.streamingReply")
            } else if tools.isEmpty {
                ThinkingBubble()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("careloop.diet.progress")
    }
}

// MARK: - 跳跃省略号气泡

struct ThinkingBubble: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(CareTheme.sage)
                    .frame(width: 8, height: 8)
                    .offset(y: animate ? -6 : 0)
                    .animation(
                        .easeInOut(duration: 0.3)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.1),
                        value: animate
                    )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white)
                .shadow(color: CareTheme.ink.opacity(0.05), radius: 4, y: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { animate = true }
    }
}
