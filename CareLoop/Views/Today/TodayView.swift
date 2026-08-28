import Charts
import SwiftData
import SwiftUI

struct TodayView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(sort: \AlertRecord.createdAt, order: .reverse) private var alerts: [AlertRecord]
    @Query private var medications: [Medication]
    @Query private var intakes: [MedicationIntake]
    @Query(sort: \FollowUp.date) private var followUps: [FollowUp]
    @State private var seriesByType: [MetricType: [DailyMetricPoint]] = [:]
    @State private var todayMetrics: [MetricType: HealthMetric] = [:]
    @State private var sleepHours: Double?
    @State private var selectedMetric: MetricType = .restingHeartRate

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
                VStack(alignment: .leading, spacing: CareTheme.sectionSpacing) {
                    statusCard
                    trendCard
                    alertList
                    medicationCard
                    followCard
                    adviceCard
                    DisclaimerBanner()
                }
                .padding()
            }
            .background(CareTheme.paper.ignoresSafeArea())
            .navigationTitle("今日")
            .task { await loadMetrics() }
        }
    }

    private var todayAlerts: [AlertRecord] {
        alerts.filter { Calendar.current.isDateInToday($0.createdAt) }
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

    // MARK: 今日状态卡

    private var statusCard: some View {
        let status = TodayStatus.from(alerts: todayAlerts)
        return VStack(alignment: .leading, spacing: 12) {
            Text("今日状态")
                .font(CareTheme.caption)
                .foregroundStyle(CareTheme.muted)
            HStack(spacing: 8) {
                Circle()
                    .fill(CareTheme.statusColor(status))
                    .frame(width: 10, height: 10)
                Text(status.rawValue)
                    .font(.title3.bold())
                    .foregroundStyle(CareTheme.ink)
                Spacer()
                Text(Date().formatted(.dateTime.month().day().weekday()))
                    .font(CareTheme.caption)
                    .foregroundStyle(CareTheme.muted)
            }
            HStack(spacing: 10) {
                MetricChipView(
                    icon: IconCatalog.icon(for: .stepCount),
                    tint: IconCatalog.color(for: .stepCount),
                    value: todayMetrics[.stepCount].map { $0.value.formatted(.number.grouping(.automatic).precision(.fractionLength(0))) } ?? "—",
                    label: "今日步数"
                )
                MetricChipView(
                    icon: IconCatalog.icon(for: .restingHeartRate),
                    tint: IconCatalog.color(for: .restingHeartRate),
                    value: todayMetrics[.restingHeartRate].map { $0.value.formatted(.number.precision(.fractionLength(0))) } ?? "—",
                    label: "静息心率 次/分"
                )
                MetricChipView(
                    icon: IconCatalog.icon(for: .sleepHours),
                    tint: IconCatalog.color(for: .sleepHours),
                    value: sleepHours.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—",
                    label: "昨晚睡眠 小时"
                )
            }
        }
        .careCard()
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

    // MARK: 异常与原因（折叠五段式）

    private var alertList: some View {
        let sorted = todayAlerts.sorted { $0.tier > $1.tier }
        return VStack(alignment: .leading, spacing: 10) {
            Label("异常与原因", systemImage: "exclamationmark.bubble")
                .font(CareTheme.cardTitle)
                .foregroundStyle(CareTheme.ink)
            if sorted.isEmpty {
                Text("目前没有需要特别展开的提示。")
                    .font(CareTheme.body)
                    .foregroundStyle(CareTheme.muted)
            }
            ForEach(sorted, id: \.id) { alert in
                alertRow(alert)
            }
        }
        .careCard()
    }

    private func alertRow(_ alert: AlertRecord) -> some View {
        let color = CareTheme.tierColor(alert.tier)
        let content = DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                labeled("与个人基线相比", alert.baselineDelta)
                labeled("为什么需要关注", alert.whyItMatters)
                labeled("建议采取的行动", alert.suggestedAction)
                labeled("证据与依据", alert.evidence)
            }
            .padding(.top, 6)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(alert.tier.displayTitle) · \(alert.title)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CareTheme.ink)
                    Text(alert.whatChanged)
                        .font(.caption)
                        .foregroundStyle(CareTheme.muted)
                        .lineLimit(2)
                }
            }
        }
        .tint(CareTheme.muted)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: CareTheme.smallCornerRadius, style: .continuous)
                .fill(color.opacity(0.06))
        )
        if let destination = insightDestination(for: alert) {
            return AnyView(
                VStack(spacing: 6) {
                    content
                    NavigationLink {
                        destination
                    } label: {
                        Label("查看指标解读与可视化", systemImage: "chart.xyaxis.line")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(CareTheme.sage)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: CareTheme.smallCornerRadius, style: .continuous)
                                    .fill(CareTheme.sageSoft)
                            )
                    }
                    .buttonStyle(.plain)
                }
            )
        }
        return AnyView(content)
    }

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

    // MARK: 今日用药

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
                .font(.caption)
                .foregroundStyle(CareTheme.muted)
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

    // MARK: 复诊 / 检查

    private var followCard: some View {
        NavigationLink {
            FollowUpDetailView(followUpID: FollowUpService.nextFollowUp(from: followUps)?.id)
        } label: {
            FollowUpSummaryCard(followUp: FollowUpService.nextFollowUp(from: followUps))
        }
        .buttonStyle(CareCardPressStyle())
    }

    // MARK: 今日一条行动建议

    private var adviceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("今日一条行动建议", systemImage: "lightbulb.fill")
                .font(CareTheme.cardTitle)
                .foregroundStyle(CareTheme.ink)
            if let advice = env.lastAdvice {
                adviceBlock(icon: "fork.knife", title: advice.recipe.title, body: advice.recipe.body)
                Divider()
                adviceBlock(icon: "figure.walk", title: advice.exercise.title, body: advice.exercise.body)
                Text(advice.recipe.disclaimer)
                    .font(.caption)
                    .foregroundStyle(CareTheme.muted)
                if advice.recipe.degraded || advice.exercise.degraded {
                    Label("当前使用本地模板生成，功能仍可用。", systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(CareTheme.muted)
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

    // MARK: 通用

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(CareTheme.muted)
            Text(value).font(CareTheme.body)
        }
    }

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
