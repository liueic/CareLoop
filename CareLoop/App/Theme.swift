import SwiftUI

enum CareTheme {
    // MARK: 品牌色
    static let sage = Color(red: 0.18, green: 0.42, blue: 0.35)
    static let sageSoft = Color(red: 0.18, green: 0.42, blue: 0.35).opacity(0.12)
    static let sageBright = Color(red: 0.30, green: 0.56, blue: 0.47)
    static let paper = Color(red: 0.97, green: 0.96, blue: 0.93)
    static let ink = Color(red: 0.16, green: 0.17, blue: 0.16)
    static let muted = Color(red: 0.42, green: 0.43, blue: 0.41)
    static let danger = Color(red: 0.66, green: 0.22, blue: 0.18)
    static let warn = Color(red: 0.72, green: 0.48, blue: 0.16)

    // MARK: 填充与底色
    static let cardBackground = Color.white
    static let track = Color(red: 0.90, green: 0.90, blue: 0.88)

    // MARK: 布局
    static let cardCornerRadius: CGFloat = 20
    static let smallCornerRadius: CGFloat = 12
    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 16

    // MARK: 字体
    static let pageTitle = Font.title2.bold()
    static let cardTitle = Font.headline
    static let body = Font.subheadline
    static let caption = Font.caption
    static let metricValue = Font.system(.title2, design: .rounded).weight(.bold)
    static let metricValueSmall = Font.system(.headline, design: .rounded).weight(.semibold)

    // MARK: 品牌渐变（主按钮 / 大卡）
    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [sageBright, sage],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: 状态语义色
    static func statusColor(_ status: TodayStatus) -> Color {
        switch status {
        case .stable: sage
        case .watch: warn
        case .consult: danger
        }
    }

    static func tierColor(_ tier: AlertTier) -> Color {
        switch tier {
        case .l1: sage
        case .l2: Color(red: 0.55, green: 0.62, blue: 0.30)
        case .l3: warn
        case .l4: danger
        case .l5: Color(red: 0.75, green: 0.12, blue: 0.12)
        }
    }

    // MARK: 热力图色阶（GitHub 风格，0 = 无记录）
    static func heatColor(level: Int) -> Color {
        switch level {
        case 1: return Color(red: 0.72, green: 0.87, blue: 0.78)
        case 2: return Color(red: 0.49, green: 0.76, blue: 0.61)
        case 3: return Color(red: 0.30, green: 0.60, blue: 0.45)
        case 4...: return Color(red: 0.16, green: 0.44, blue: 0.32)
        default: return track
        }
    }
}

struct DisclaimerBanner: View {
    var compact: Bool = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(CareLoopCopy.medicalDisclaimer)
            if !compact {
                Text(CareLoopCopy.notADiagnosis)
            }
        }
        .font(.caption)
        .foregroundStyle(CareTheme.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("careloop.disclaimer")
    }
}
