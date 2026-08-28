import SwiftUI

/// GitHub 风格的坚持记录热力图：列 = 周，行 = 周一…周日。
struct ActivityHeatmapView: View {
    let counts: [Date: Int]
    var weeksBack: Int = 11
    @State private var selected: Date?

    private let cell: CGFloat = 14
    private let spacing: CGFloat = 3

    var body: some View {
        let weeks = ActivityHeatmap.weeks(weeksBack: weeksBack)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: spacing) {
                weekdayLabels
                ForEach(weeks) { week in
                    VStack(spacing: spacing) {
                        ForEach(0..<7, id: \.self) { row in
                            cellView(for: week.days[row])
                        }
                    }
                }
            }
            HStack {
                legend
                Spacer()
                if let selected {
                    Text("\(selected.formatted(.dateTime.month().day())) · \(counts[selected] ?? 0) 条记录")
                        .font(.caption)
                        .foregroundStyle(CareTheme.muted)
                }
            }
        }
    }

    private var weekdayLabels: some View {
        VStack(spacing: spacing) {
            ForEach(0..<7, id: \.self) { row in
                Text(row == 0 ? "一" : row == 3 ? "四" : row == 6 ? "日" : "")
                    .font(.system(size: 9))
                    .foregroundStyle(CareTheme.muted)
                    .frame(width: 12, height: cell)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("少")
                .font(.system(size: 9))
                .foregroundStyle(CareTheme.muted)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(CareTheme.heatColor(level: level))
                    .frame(width: 10, height: 10)
            }
            Text("多")
                .font(.system(size: 9))
                .foregroundStyle(CareTheme.muted)
        }
    }

    @ViewBuilder
    private func cellView(for day: Date?) -> some View {
        if let day {
            let isToday = Calendar.current.isDateInToday(day)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(CareTheme.heatColor(level: ActivityHeatmap.level(for: counts[day] ?? 0)))
                .frame(width: cell, height: cell)
                .overlay {
                    if isToday {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(CareTheme.sage, lineWidth: 1.5)
                    }
                }
                .onTapGesture { selected = day }
                .accessibilityLabel("\(day.formatted(.dateTime.month().day()))，\(counts[day] ?? 0) 条记录")
        } else {
            Color.clear.frame(width: cell, height: cell)
        }
    }
}
