import SwiftData
import SwiftUI
import CoreSpotlight

/// 饱饱 · 饮食陪伴对话页。
struct DietChatView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var messages: [BaobaoMessage] = []
    @State private var isThinking = false
    @State private var selection: BaobaoSelection?
    @State private var showClearConfirm = false
    @State private var trendSummary = ""
    @State private var recentGlucose: String?
    @State private var recentBloodPressure: String?
    @State private var retainedAgent: (any DietAgentSession)?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                selectionBanner
                conversation
                Divider()
                suggestionArea
                inputBar
            }
            .background(Color(red: 0.98, green: 0.98, blue: 0.97).ignoresSafeArea())
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
                    if isThinking {
                        ThinkingBubble()
                            .id("thinking")
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: isThinking) { _, _ in scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation {
            if isThinking {
                proxy.scrollTo("thinking", anchor: .bottom)
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
                        .fill(Color(red: 0.94, green: 0.94, blue: 0.94))
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .baobao:
            VStack(alignment: .leading, spacing: 8) {
                if message.isConfirmation {
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
                    if let recipes = message.suggestedRecipes, !recipes.isEmpty, selection == nil {
                        HStack(spacing: 8) {
                            ForEach(recipes.prefix(2)) { recipe in
                                Button {
                                    confirm(recipe)
                                } label: {
                                    Text("就这个吧 ✓")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(Capsule().fill(CareTheme.sage))
                                }
                                .buttonStyle(.plain)
                            }
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
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isThinking)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.white)
    }

    // MARK: 发送与确认

    private func send() async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        input = ""
        messages.append(BaobaoMessage(role: .user, text: trimmed))

        isThinking = true
        let profile = env.profile()
        let tags = profile.desensitizedTags()
        let safeRecipes = AdviceEngine.hardFilterRecipes(env.recipes, profile: tags, dietRules: env.dietRules)
        let reply = await makeReply(to: trimmed, tags: tags, safeRecipes: safeRecipes)
        isThinking = false
        messages.append(reply)
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

    private func makeReply(to text: String, tags: ProfileTags, safeRecipes: [Recipe]) async -> BaobaoMessage {
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

        // 一般提问：走饮食助手，用安全候选组织回答
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
        let agent = retainedAgent ?? DietAgentFactory.make(llm: env.currentLLM())
        retainedAgent = agent
        if let response = try? await agent.respond(to: text, context: context) {
            let cited = safeRecipes.filter { response.citedRecipeIDs.contains($0.id) }
            return BaobaoMessage(
                role: .baobao,
                text: response.reply,
                suggestedRecipes: Array(cited.prefix(2))
            )
        }
        return BaobaoMessage(role: .baobao, text: BaobaoPersona.noMatchReply)
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
    var isConfirmation = false
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
