import SwiftUI

/// 指标详情页：参考区间量表 + 偏离方向 + 风险解读 + 行动建议。
struct MetricInsightView: View {
    let deviation: MetricDeviation

    @Environment(AppEnvironment.self) private var env
    @State private var insight: MetricInsight?
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CareTheme.sectionSpacing) {
                gaugeCard
                interpretationCard
                riskCard
                actionCard
                disclaimerCard
            }
            .padding()
        }
        .background(CareTheme.paper.ignoresSafeArea())
        .navigationTitle(deviation.type.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: 量表卡（当前值 vs 参考区间）

    private var gaugeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(deviation.valueText)
                    .font(CareTheme.metricValue)
                    .foregroundStyle(CareTheme.ink)
                Text(deviation.type.unit)
                    .font(CareTheme.caption)
                    .foregroundStyle(CareTheme.muted)
            }
            ReferenceRangeGauge(deviation: deviation)
                .frame(height: 46)
            HStack(spacing: 6) {
                Image(systemName: deviation.direction == .above ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill")
                Text("当前值\(deviation.directionText)参考标准 · \(deviation.rangeText)")
            }
            .font(.caption)
            .foregroundStyle(CareTheme.danger)
            if let note = deviation.threshold.guideline ?? deviation.type.wearableReferenceNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(CareTheme.muted)
            }
        }
        .careCard()
    }

    // MARK: 解读

    private var interpretationCard: some View {
        insightSection(
            title: "详细解读",
            icon: "text.magnifyingglass",
            items: insight?.interpretation ?? []
        )
    }

    private var riskCard: some View {
        insightSection(
            title: "潜在风险",
            icon: "exclamationmark.triangle",
            items: insight?.risks ?? [],
            tint: CareTheme.danger
        )
    }

    private var actionCard: some View {
        insightSection(
            title: "您的行动清单",
            icon: "checklist",
            items: insight?.actions ?? [],
            tint: CareTheme.sage
        )
    }

    private func insightSection(
        title: String,
        icon: String,
        items: [String],
        tint: Color = CareTheme.ink
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(CareTheme.cardTitle)
                .foregroundStyle(CareTheme.ink)
            if isLoading && insight == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在生成解读…")
                        .font(CareTheme.body)
                        .foregroundStyle(CareTheme.muted)
                }
            } else if items.isEmpty {
                Text("暂无内容。")
                    .font(CareTheme.body)
                    .foregroundStyle(CareTheme.muted)
            } else {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(tint)
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)
                        Text(item)
                            .font(CareTheme.body)
                            .foregroundStyle(CareTheme.ink)
                    }
                }
            }
        }
        .careCard()
    }

    private var disclaimerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let insight, !insight.visualization.isEmpty {
                Label("可视化建议", systemImage: "chart.bar.doc.horizontal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CareTheme.muted)
                Text(insight.visualization)
                    .font(.caption)
                    .foregroundStyle(CareTheme.muted)
            }
            if let insight {
                Text(insight.disclaimer)
                    .font(.caption)
                    .foregroundStyle(CareTheme.muted)
                if !insight.usedLLM {
                    Label("当前使用本地模板生成，功能仍可用。", systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(CareTheme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let conditions = env.profile().conditions
        insight = await MetricInsightService.generate(
            deviation: deviation,
            conditions: conditions,
            doctorAdvice: nil,
            llm: env.currentLLM()
        )
    }
}

// MARK: - 参考区间量表

/// Apple Health 风格的横向量表：绿色为参考区间，红点标示当前值位置。
struct ReferenceRangeGauge: View {
    let deviation: MetricDeviation

    private var low: Double {
        if let low = deviation.threshold.low { return low }
        let bound = deviation.exceededBound
        return min(bound * 0.5, deviation.value * 0.5)
    }

    private var high: Double {
        if let high = deviation.threshold.high { return high }
        let bound = deviation.exceededBound
        return max(bound * 1.5, deviation.value * 1.2)
    }

    private var safeLow: Double { deviation.threshold.low ?? low }
    private var safeHigh: Double { deviation.threshold.high ?? high }

    private func position(_ value: Double, in width: CGFloat) -> CGFloat {
        let span = high - low
        guard span > 0 else { return width / 2 }
        let clamped = min(max(value, low), high)
        return CGFloat((clamped - low) / span) * width
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(CareTheme.track)
                Capsule()
                    .fill(CareTheme.sage.opacity(0.45))
                    .frame(width: position(safeHigh, in: width) - position(safeLow, in: width))
                    .offset(x: position(safeLow, in: width))
                Circle()
                    .fill(CareTheme.danger)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .offset(x: position(deviation.value, in: width) - 7)
            }
            .frame(height: 14)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .accessibilityElement()
        .accessibilityLabel("\(deviation.type.displayName)当前值\(deviation.valueText)，\(deviation.directionText)参考标准，\(deviation.rangeText)")
    }
}

// MARK: - 代谢综合征概览页

struct MetabolicInsightView: View {
    let input: MetabolicSyndromeInput

    @Environment(AppEnvironment.self) private var env
    @State private var insight: MetricInsight?
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CareTheme.sectionSpacing) {
                summaryCard
                if let insight {
                    section(title: "详细解读", icon: "text.magnifyingglass", items: insight.interpretation)
                    section(title: "潜在风险", icon: "exclamationmark.triangle", items: insight.risks, tint: CareTheme.danger)
                    section(title: "您的行动清单", icon: "checklist", items: insight.actions, tint: CareTheme.sage)
                    if !insight.visualization.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("可视化建议", systemImage: "chart.bar.doc.horizontal")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(CareTheme.muted)
                            Text(insight.visualization)
                                .font(.caption)
                                .foregroundStyle(CareTheme.muted)
                            Text(insight.disclaimer)
                                .font(.caption)
                                .foregroundStyle(CareTheme.muted)
                        }
                    }
                } else if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在生成解读…")
                            .font(CareTheme.body)
                            .foregroundStyle(CareTheme.muted)
                    }
                }
            }
            .padding()
        }
        .background(CareTheme.paper.ignoresSafeArea())
        .navigationTitle("代谢健康概览")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("发现 \(input.abnormalCount)/\(input.items.count) 项异常指标")
                .font(.title3.bold())
                .foregroundStyle(input.abnormalCount > 0 ? CareTheme.danger : CareTheme.sage)
            ForEach(input.items) { item in
                HStack {
                    Circle()
                        .fill(item.abnormal ? CareTheme.danger : CareTheme.sage)
                        .frame(width: 8, height: 8)
                    Text(item.name)
                        .font(CareTheme.body)
                    Spacer()
                    Text(item.valueText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(CareTheme.ink)
                    Text(item.abnormal ? "\(item.directionText)标准" : "正常")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill((item.abnormal ? CareTheme.danger : CareTheme.sage).opacity(0.12)))
                        .foregroundStyle(item.abnormal ? CareTheme.danger : CareTheme.sage)
                }
            }
        }
        .careCard()
    }

    private func section(title: String, icon: String, items: [String], tint: Color = CareTheme.ink) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(CareTheme.cardTitle)
                .foregroundStyle(CareTheme.ink)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(tint)
                        .frame(width: 5, height: 5)
                        .padding(.top, 6)
                    Text(item)
                        .font(CareTheme.body)
                        .foregroundStyle(CareTheme.ink)
                }
            }
        }
        .careCard()
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        insight = await MetricInsightService.generateMetabolic(
            input: input,
            conditions: env.profile().conditions,
            doctorAdvice: nil,
            llm: env.currentLLM()
        )
    }
}
