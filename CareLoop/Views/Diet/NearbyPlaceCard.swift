import SwiftUI

/// 附近餐厅卡片：名称 + 菜系 + 距离 + 地址 + 「导航」按钮（高德通用链接唤起）。
struct NearbyPlaceCard: View {
    let place: NearbyPlace
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(place.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CareTheme.ink)
                        .lineLimit(1)
                    Text(place.type)
                        .font(.caption2)
                        .foregroundStyle(CareTheme.sage)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(CareTheme.sageSoft))
                    if let distance = place.distanceText {
                        Text(distance)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(CareTheme.muted)
                    }
                }
                if !place.address.isEmpty {
                    Text(place.address)
                        .font(.caption2)
                        .foregroundStyle(CareTheme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button {
                openURL(place.navigationURL)
            } label: {
                Label("导航", systemImage: "location.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(CareTheme.sage))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("导航到\(place.name)")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white)
                .shadow(color: CareTheme.ink.opacity(0.05), radius: 4, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(CareTheme.sage.opacity(0.35), lineWidth: 1)
        )
    }
}
