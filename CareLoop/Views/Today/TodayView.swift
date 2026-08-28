import Charts
import SwiftData
import SwiftUI

struct TodayView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(sort: \AlertRecord.createdAt, order: .reverse) private var alerts: [AlertRecord]
    @Query private var medications: [Medication]
    @Query private var intakes: [MedicationIntake]
    @Query(sort: \FollowUp.date) private var followUps: [FollowUp]
    @Query(sort: \DailyLogEntry.createdAt, order: .reverse) private var logs: [DailyLogEntry]
    @State private var seriesByType: [MetricType: [DailyMetricPoint]] = [:]
    @State private var todayMetrics: [MetricType: HealthMetric] = [:]
    @State private var sleepHours: Double?
    @State private var selectedMetric: MetricType = .restingHeartRate
    @State private var showDietChat = false
    @State private var showRiskList = false

    /// 趋势图可切换的指标，按病种相关度排序。
    private let chartMetrics: [MetricType] = [
        .restingHeartRate, .sleepHours, .stepCount, .bloodPressureSystolic, .bloodGlucose
    ]

    /// 解读页需要取值的附加指标（代谢综合征相关等）。
    private let insightMetrics: [MetricType] = [
        .bloodPressureDiastolic, .triglycerides, .hdlCholesterol, .waistCircumference,
        .sleepREMPercent, .sleepDeepPercent, .afBurden, .cgmTIR
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    followUpCard
                    medicationCard
                    adviceCard
                    riskBanner
                    trendCard
                    DisclaimerBanner()
                }
                .padding()
            }
            .background(CareTheme.paper.ignoresSafeArea())
            .navigationTitle("今日")
            .task { await loadMetrics() }
            .sheet(isPresented: $showDietChat) {
                DietChatView()
            }
            .sheet(isPresented: $showRiskList) {
                RiskListSheet(
                    alerts: todayAlerts,
                    destination: { alert in insightDestination(for: alert) }
                )
                .presentationDetents([.medium, .large])
            }
        }
    }

    private var todayAlerts: [AlertRecord] {
        alerts
            .filter { Calendar.current.isDateInToday($0.createdAt) }
            .sorted { $0.tier > $1.tier }
    }

    // MARK: 数据加载

    private func loadMetrics() async {
        let provider = env.healthProvider
        for type in chartMetrics {
            seriesByType[type] = await provider.dailySeries(type, days: 14)
            if let metric = await provider.metric(type, on: Date()) {
                todayMetrics[type] = metric
            }
        }
        for type in insightMetrics where todayMetrics[type] == nil {
            if let metric = await provider.metric(type, on: Date()) {
                todayMetrics[type] = metric
            }
        }
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        sleepHours = await provider.metric(.sleepHours, on: yesterday)?.value
        if let firstAvailable = chartMetrics.first(where: { !(seriesByType[$0] ?? []).isEmpty }),
           (seriesByType[selectedMetric] ?? []).isEmpty {
            selectedMetric = firstAvailable
        }
    }

    // MARK: 区块一：下次复诊（置顶）

    private var followUpCard: some View {
        Group {
            if let next = FollowUpService.nextFollowUp(from: followUps) {
                NavigationLink {
                    FollowUpDetailView(followUpID: next.id)
                } label: {
                    HStack(spacing: 14) {
                        FollowUpCountdownRing(date: next.date, size: 64, lineWidth: 5)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("下次复诊")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(CareTheme.sage)
                                Spacer()
                                FollowUpCountdownBadge(
                                    text: next.countdownText,
                                    urgency: FollowUpService.urgencyLevel(for: next.date)
                                )
                            }
                            Text("\(next.department) · \(next.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(CareTheme.ink)
                            if !next.doctorName.isEmpty {
                                Label(next.doctorName, systemImage: "person.fill")
                                    .font(.caption)
                                    .foregroundStyle(CareTheme.muted)
                            }
                            FollowUpChipRow(
                                icon: "exclamationmark.circle",
                                tint: CareTheme.warn,
                                items: next.effectiveRestrictions
                            )
                            FollowUpChipRow(
                                icon: "doc.text",
                                tint: CareTheme.sage,
                                items: next.effectiveMaterials
                            )
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(CareTheme.muted)
                    }
                    .padding(CareTheme.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [CareTheme.sage.opacity(0.10), CareTheme.sage.opacity(0.04)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(CareTheme.sage.opacity(0.18), lineWidth: 1)
                    )
                }
                .buttonStyle(CareCardPressStyle())
            } else {
                NavigationLink {
                    FollowUpDetailView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "calendar.badge.plus")
                            .font(.title3)
                            .foregroundStyle(CareTheme.sage)
                        Text("安排下次复诊")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(CareTheme.ink)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(CareTheme.muted)
                    }
                    .padding(CareTheme.cardPadding)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.white)
                    )
                    .shadow(color: CareTheme.ink.opacity(0.06), radius: 8, y: 2)
                }
                .buttonStyle(CareCardPressStyle())
            }
        }
    }

    // MARK: 区块二：今日用药

    private var medicationCard: some View {
        let slots = MedicationEngine.markMissedIfNeeded(
            slots: MedicationEngine.slotsForDay(medications: medications, intakes: intakes, day: Date())
        )
        let taken = slots.filter { $0.status == .taken }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("今日用药", systemImage: "pills.fill")
                    .font(CareTheme.cardTitle)
                    .foregroundStyle(CareTheme.ink)
                Spacer()
                if !slots.isEmpty {
                    progressRing(taken: taken, total: slots.count)
                }
            }
            if slots.isEmpty {
                Text("还没有用药计划。")
                    .font(CareTheme.body)
                    .foregroundStyle(CareTheme.muted)
            }
            ForEach(slots) { slot in
                HStack(spacing: 10) {
                    Circle()
                        .fill(slotColor(slot.status))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(slot.name)
                            .font(CareTheme.body)
                            .foregroundStyle(CareTheme.ink)
                        Text("\(slot.dose) · \(slot.scheduledTime.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(CareTheme.muted)
                    }
                    Spacer()
                    Button(slot.status == .taken ? "已服" : "打卡") {
                        mark(slot)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(slot.status == .taken ? CareTheme.sageSoft : CareTheme.sage))
                    .foregroundStyle(slot.status == .taken ? CareTheme.sage : .white)
                    .disabled(slot.status == .taken)
                }
            }
            Text(MedicationEngine.missedHint)
                .font(.caption2)
                .foregroundStyle(CareTheme.muted.opacity(0.8))
        }
        .careCard()
    }

    private func progressRing(taken: Int, total: Int) -> some View {
        let ratio = total > 0 ? Double(taken) / Double(total) : 0
        return ZStack {
            Circle()
                .stroke(CareTheme.track, lineWidth: 5)
            Circle()
                .trim(from: 0, to: ratio)
                .stroke(CareTheme.sage, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(taken)/\(total)")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(CareTheme.ink)
        }
        .frame(width: 44, height: 44)
        .animation(.easeOut, value: ratio)
        .accessibilityLabel("今日已服 \(taken)，共 \(total)")
    }

    private func slotColor(_ status: IntakeStatus) -> Color {
        switch status {
        case .taken: CareTheme.sage
        case .missed: CareTheme.danger
        case .skipped: CareTheme.warn
        case .scheduled: CareTheme.track
        }
    }

    // MARK: 区块三：行动建议

    private var adviceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("今日一条行动建议", systemImage: "lightbulb.fill")
                    .font(CareTheme.cardTitle)
                    .foregroundStyle(CareTheme.ink)
                Spacer()
                Button("饮食问一问") { showDietChat = true }
                    .font(.caption.bold())
            }
            if let picked = BaobaoState.selection() {
                adviceBlock(
                    icon: "fork.knife",
                    title: "今日菜单：\(picked.recipeName)",
                    body: "烹调少盐少糖，按你的口味来。这不是医疗建议。"
                )
                Text("依据：你的选择")
                    .font(.caption2)
                    .foregroundStyle(CareTheme.muted.opacity(0.8))
            } else if let advice = env.lastAdvice {
                adviceBlock(icon: "fork.knife", title: advice.recipe.title, body: advice.recipe.body)
                dietClauseFootnotes(for: advice.recipe.clauseCitationIDs)
                Divider()
                adviceBlock(icon: "figure.walk", title: advice.exercise.title, body: advice.exercise.body)
                Text(advice.recipe.disclaimer)
                    .font(.caption2)
                    .foregroundStyle(CareTheme.muted.opacity(0.8))
                if advice.recipe.degraded || advice.exercise.degraded {
                    Label("当前使用本地模板生成，功能仍可用。", systemImage: "wifi.slash")
                        .font(.caption2)
                        .foregroundStyle(CareTheme.muted.opacity(0.8))
                }
            } else {
                Text("正在准备建议…")
                    .font(CareTheme.body)
                    .foregroundStyle(CareTheme.muted)
            }
        }
        .careCard()
    }

    private func adviceBlock(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(CareTheme.sage)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(body).font(CareTheme.body).foregroundStyle(CareTheme.ink)
            }
        }
    }

    // MARK: 区块四：风险横幅（下沉）

    @ViewBuilder
    private var riskBanner: some View {
        if let top = todayAlerts.first {
            let extra = todayAlerts.count - 1
            Button {
                showRiskList = true
            } label: {
                HStack(spacing: 10) {
                    AlertBadge(alert: top)
                    Text(top.briefMetricName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CareTheme.ink)
                        .lineLimit(1)
                    if extra > 0 {
                        Text("+\(extra)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(CareTheme.danger)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(CareTheme.danger.opacity(0.12)))
                    }
                    Spacer()
                    Text("查看详情")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(CareTheme.sage)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(CareTheme.sage)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(red: 1.0, green: 0.94, blue: 0.93))
                )
            }
            .buttonStyle(CareCardPressStyle())
        }
    }

    // MARK: 多指标趋势图

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("近 14 天趋势", systemImage: "chart.line.uptrend.xyaxis")
                .font(CareTheme.cardTitle)
                .foregroundStyle(CareTheme.ink)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chartMetrics) { type in
                        metricPickerButton(type)
                    }
                }
            }
            let points = seriesByType[selectedMetric] ?? []
            if points.isEmpty {
                ContentUnavailableView(
                    "暂无\(selectedMetric.displayName)数据",
                    systemImage: IconCatalog.icon(for: selectedMetric),
                    description: Text("连接数据来源后会自动生成趋势")
                )
                .frame(height: 160)
            } else {
                TrendChartView(points: points, metricType: selectedMetric)
                    .frame(height: 180)
                Text("来源：\(points.last?.sourceName ?? env.healthProvider.sourceLabel)")
                    .font(.caption2)
                    .foregroundStyle(CareTheme.muted)
            }
        }
        .careCard()
    }

    private func metricPickerButton(_ type: MetricType) -> some View {
        let selected = type == selectedMetric
        let hasData = !(seriesByType[type] ?? []).isEmpty
        return Button {
            selectedMetric = type
        } label: {
            HStack(spacing: 4) {
                Image(systemName: IconCatalog.icon(for: type))
                    .font(.caption)
                Text(type.displayName)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(selected ? IconCatalog.color(for: type) : CareTheme.sageSoft)
            )
            .foregroundStyle(selected ? .white : CareTheme.ink)
        }
        .buttonStyle(.plain)
        .opacity(hasData || selected ? 1 : 0.45)
    }

    // MARK: 解读页入口解析

    /// 从告警内容解析出对应指标与数值，生成解读页入口。
    private func insightDestination(for alert: AlertRecord) -> AnyView? {
        if alert.title.contains("代谢综合征") || alert.whatChanged.contains("代谢综合征") {
            return AnyView(MetabolicInsightView(input: metabolicInput()))
        }
        for raw in alert.relatedMetricTypes {
            guard let type = MetricType(rawValue: raw),
                  let threshold = env.rules.populationThresholds[raw],
                  let value = extractValue(from: alert.whatChanged) else { continue }
            let info = MetricThresholdInfo(
                low: threshold.low,
                high: threshold.high,
                unit: threshold.unit,
                guideline: threshold.guideline
            )
            let direction: MetricDeviation.Direction
            if let high = threshold.high, value >= high {
                direction = .above
            } else if let low = threshold.low, value <= low {
                direction = .below
            } else {
                continue
            }
            return AnyView(
                MetricInsightView(
                    deviation: MetricDeviation(type: type, value: value, direction: direction, threshold: info)
                )
            )
        }
        return nil
    }

    private func extractValue(from text: String) -> Double? {
        guard let range = text.range(of: #"[0-9]+(\.[0-9]+)?"#, options: .regularExpression) else { return nil }
        return Double(text[range])
    }

    private func metabolicInput() -> MetabolicSyndromeInput {
        MetabolicSyndromeInput(
            waist: todayMetrics[.waistCircumference]?.value,
            triglycerides: todayMetrics[.triglycerides]?.value,
            systolic: todayMetrics[.bloodPressureSystolic]?.value,
            diastolic: todayMetrics[.bloodPressureDiastolic]?.value,
            fastingGlucose: todayMetrics[.bloodGlucose]?.value,
            hdl: todayMetrics[.hdlCholesterol]?.value,
            isFemale: env.profile().biologicalSex == .female
        )
    }

    private func dietClauseFootnotes(for ids: [String]) -> some View {
        let clauses = env.dietRules.clauses(withIDs: ids)
        return Group {
            if !clauses.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(clauses) { clause in
                        Text("依据：\(clause.title)")
                            .font(.caption2)
                            .foregroundStyle(CareTheme.muted)
                    }
                }
                .padding(.leading, 32)
            }
        }
    }

    // MARK: 用药打卡

    private func mark(_ slot: MedicationSlot) {
        if let existing = intakes.first(where: { $0.id == slot.id }) {
            existing.status = .taken
            existing.takenAt = Date()
        } else if let med = medications.first(where: { $0.id == slot.medicationID }) {
            let intake = MedicationIntake(medication: med, scheduledTime: slot.scheduledTime, status: .taken)
            intake.takenAt = Date()
            env.context.insert(intake)
        }
        try? env.context.save()
    }
}

// MARK: - 风险徽章（结论标签）

struct AlertBadge: View {
    let alert: AlertRecord

    private var text: String {
        if alert.tier == .l5 { return "尽快就医" }
        if alert.title.contains("持续") { return "持续偏离" }
        let name = alert.briefMetricName
        if MetricType.allCases.contains(where: { $0.higherIsWorse && name.contains($0.displayName) }) {
            return "偏高"
        }
        return "偏低"
    }

    private var tint: Color {
        switch alert.tier {
        case .l5: Color(red: 0.75, green: 0.12, blue: 0.12)
        case .l4: Color(red: 0.90, green: 0.30, blue: 0.27)
        case .l3: CareTheme.warn
        default: CareTheme.sage
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint)
                    .shadow(color: tint.opacity(0.35), radius: 2, y: 1)
            )
    }
}

// MARK: - 风险列表（精简卡片）

struct RiskListSheet: View {
    let alerts: [AlertRecord]
    let destination: (AlertRecord) -> AnyView?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(alerts, id: \.id) { alert in
                        RiskCard(alert: alert, destination: destination(alert))
                    }
                    if alerts.isEmpty {
                        Text("目前没有需要特别关注的提示。")
                            .font(CareTheme.body)
                            .foregroundStyle(CareTheme.muted)
                            .padding(.top, 40)
                    }
                }
                .padding()
            }
            .background(CareTheme.paper.ignoresSafeArea())
            .navigationTitle("风险提示")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(CareTheme.sage)
                }
            }
        }
    }
}

struct RiskCard: View {
    let alert: AlertRecord
    let destination: AnyView?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                AlertBadge(alert: alert)
                if alert.title.contains("持续") {
                    Text("持续")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(CareTheme.warn)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(CareTheme.warn.opacity(0.12)))
                }
                Spacer()
                Image(systemName: "stethoscope")
                    .font(.caption)
                    .foregroundStyle(CareTheme.muted.opacity(0.6))
            }
            Text(alert.briefMetricName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(red: 0.10, green: 0.10, blue: 0.10))
            Text(alert.briefValueText)
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 0.53, green: 0.53, blue: 0.53))
                .lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                Text(alert.briefRiskText)
                    .font(.system(size: 13))
            }
            .foregroundStyle(alert.tier >= .l4 ? Color(red: 0.90, green: 0.30, blue: 0.27) : Color(red: 0.96, green: 0.65, blue: 0.14))
            if let destination {
                HStack {
                    Spacer()
                    NavigationLink {
                        destination
                    } label: {
                        Text("指标解读 →")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(CareTheme.sage)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white)
                .shadow(color: CareTheme.ink.opacity(0.08), radius: 8, y: 2)
        )
    }
}

// MARK: - 告警简报

extension AlertRecord {
    /// 去掉 tier 前缀与冗余说明后的指标名称。
    var briefMetricName: String {
        var name = title
        for tier in AlertTier.allCases {
            name = name.replacingOccurrences(of: tier.displayTitle, with: "")
        }
        for filler in ["指南评估:", "指南评估：", "·", "越过指南参考线"] {
            name = name.replacingOccurrences(of: filler, with: "")
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? whatChanged : name
    }

    /// 核心数值 + 参考范围的一行摘要。
    var briefValueText: String {
        if let range = whatChanged.range(of: #"[0-9]+(\.[0-9]+)?\s*[a-zA-Z%步小时/]*"#, options: .regularExpression) {
            return String(whatChanged[range])
        }
        return String(whatChanged.prefix(30))
    }

    /// 一句话风险简述。
    var briefRiskText: String {
        let text = whyItMatters
        if text.isEmpty { return suggestedAction }
        let sentence = text.split(whereSeparator: "。；;".contains).first.map(String.init) ?? text
        return String(sentence.prefix(40))
    }
}
