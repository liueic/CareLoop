import SwiftUI

/// 全局统一的卡片样式：白底、圆角、浅阴影。
struct CareCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(CareTheme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CareTheme.cardCornerRadius, style: .continuous)
                    .fill(CareTheme.cardBackground)
                    .shadow(color: CareTheme.ink.opacity(0.06), radius: 8, y: 2)
            )
    }
}

extension View {
    func careCard() -> some View {
        modifier(CareCard())
    }
}

/// 手帐标签的彩色 chip。
struct TagChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// 关键指标小卡：图标 + rounded 数字 + 说明。
struct MetricChipView: View {
    let icon: String
    let tint: Color
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(tint)
            Text(value)
                .font(CareTheme.metricValueSmall)
                .monospacedDigit()
                .foregroundStyle(CareTheme.ink)
            Text(label)
                .font(.caption2)
                .foregroundStyle(CareTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: CareTheme.smallCornerRadius, style: .continuous)
                .fill(tint.opacity(0.08))
        )
    }
}
