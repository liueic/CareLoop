import SwiftData
import SwiftUI
import CoreSpotlight

struct DietChatView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var messages: [DietChatMessage] = []
    @State private var isSending = false
    @State private var trendSummary = ""
    @State private var recentGlucose: String?
    @State private var recentBloodPressure: String?
    @State private var retainedAgent: (any DietAgentSession)?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            introCard
                            ForEach(messages) { message in
                                chatBubble(message)
                                    .id(message.id)
                            }
                            if isSending {
                                ProgressView("正在思考…")
                                    .font(CareTheme.caption)
                                    .foregroundStyle(CareTheme.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                Divider()
                inputBar
            }
            .background(CareTheme.paper.ignoresSafeArea())
            .navigationTitle("饮食问一问")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await prepareSession() }
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("我可以基于你的画像、今日状态与饮食指南，从安全食谱里帮你组合建议。")
                .font(CareTheme.body)
                .foregroundStyle(CareTheme.ink)
            Text(CareLoopCopy.aiAdviceDisclaimer)
                .font(.caption)
                .foregroundStyle(CareTheme.muted)
        }
        .careCard()
    }

    private func chatBubble(_ message: DietChatMessage) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            Text(message.text)
                .font(CareTheme.body)
                .foregroundStyle(message.role == .user ? .white : CareTheme.ink)
                .padding(12)
                .background(message.role == .user ? CareTheme.sage : Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            if !message.citedClauseIDs.isEmpty, message.role == .assistant {
                clauseFootnotes(message.citedClauseIDs)
            }
            if message.degraded {
                Label("当前使用本地模板或降级回答", systemImage: "wifi.slash")
                    .font(.caption2)
                    .foregroundStyle(CareTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private func clauseFootnotes(_ ids: [String]) -> some View {
        let clauses = env.dietRules.clauses(withIDs: ids)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(clauses) { clause in
                Text("依据：\(clause.title)（\(clause.source)）")
                    .font(.caption2)
                    .foregroundStyle(CareTheme.muted)
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("例如：今晚吃什么？", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
            Button {
                Task { await send() }
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        }
        .padding()
        .background(.ultraThinMaterial)
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

    private func send() async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        input = ""
        let userMessage = DietChatMessage(role: .user, text: trimmed)
        messages.append(userMessage)
        isSending = true
        defer { isSending = false }

        let profile = env.profile()
        let alerts = (try? env.context.fetch(FetchDescriptor<AlertRecord>())) ?? []
        let logs = (try? env.context.fetch(FetchDescriptor<DailyLogEntry>())) ?? []
        let context = DietAgentContext(
            profile: profile.desensitizedTags(),
            trendSummary: trendSummary,
            todayStatus: TodayStatus.from(alerts: alerts.filter { Calendar.current.isDateInToday($0.createdAt) }).rawValue,
            recipes: env.recipes,
            dietRules: env.dietRules,
            guardrailRules: env.rules,
            history: messages.dropLast().map { ($0.role.rawValue, $0.text) },
            recentDietLogSummary: DietTools.dietLogSummary(entries: logs),
            recentGlucose: recentGlucose,
            recentBloodPressure: recentBloodPressure,
            currentMedicationNames: profile.currentMedicationNames
        )

        let agent = retainedAgent ?? DietAgentFactory.make(llm: env.currentLLM())
        retainedAgent = agent
        do {
            let response = try await agent.respond(to: trimmed, context: context)
            messages.append(
                DietChatMessage(
                    role: .assistant,
                    text: response.reply,
                    citedClauseIDs: response.citedClauseIDs,
                    degraded: response.degraded
                )
            )
        } catch {
            messages.append(
                DietChatMessage(
                    role: .assistant,
                    text: error.localizedDescription,
                    citedClauseIDs: [],
                    degraded: true
                )
            )
        }
    }
}

struct DietChatMessage: Identifiable {
    enum Role: String {
        case user
        case assistant
    }

    var id = UUID()
    var role: Role
    var text: String
    var citedClauseIDs: [String] = []
    var degraded = false
}
