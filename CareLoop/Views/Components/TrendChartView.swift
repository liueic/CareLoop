import Charts
import SwiftUI

/// 单指标日级趋势图：折线 + 渐变面积 + 均值虚线。
struct TrendChartView: View {
    let points: [DailyMetricPoint]
    let metricType: MetricType

    private var tint: Color { IconCatalog.color(for: metricType) }
    private var mean: Double? {
        guard !points.isEmpty else { return nil }
        return points.map(\.value).reduce(0, +) / Double(points.count)
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("日", point.day, unit: .day),
                    y: .value(metricType.unit, point.value)
                )
                .foregroundStyle(tint.opacity(0.15).gradient)
                .interpolationMethod(.catmullRom)
                LineMark(
                    x: .value("日", point.day, unit: .day),
                    y: .value(metricType.unit, point.value)
                )
                .foregroundStyle(tint)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .symbol(Circle().strokeBorder(lineWidth: 1.5))
                .symbolSize(20)
            }
            if let mean {
                RuleMark(y: .value("均值", mean))
                    .foregroundStyle(CareTheme.muted)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("均值 \(mean.formatted(.number.precision(.fractionLength(0...1))))")
                            .font(.caption2)
                            .foregroundStyle(CareTheme.muted)
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month().day(), centered: true)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
    }
}
