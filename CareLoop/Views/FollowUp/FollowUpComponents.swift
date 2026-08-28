import SwiftUI
import UIKit

enum FollowUpUrgency: Sendable {
    case relaxed
    case soon
    case tomorrow
    case today
    case overdue

    static func from(days: Int) -> FollowUpUrgency {
        switch days {
        case ..<0: return .overdue
        case 0: return .today
        case 1: return .tomorrow
        case 2...7: return .soon
        default: return .relaxed
        }
    }

    var tint: Color {
        switch self {
        case .relaxed: CareTheme.sage
        case .soon: CareTheme.warn
        case .tomorrow: CareTheme.warn
        case .today: CareTheme.danger
        case .overdue: CareTheme.muted
        }
    }
}

// MARK: - Interaction

struct CareCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .brightness(configuration.isPressed ? -0.015 : 0)
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

struct CareStaggerAppear: ViewModifier {
    let index: Int
    let active: Bool

    func body(content: Content) -> some View {
        content
            .opacity(active ? 1 : 0)
            .offset(y: active ? 0 : 14)
            .animation(
                .spring(response: 0.45, dampingFraction: 0.86)
                    .delay(Double(index) * 0.06),
                value: active
            )
    }
}

extension View {
    func careStaggerAppear(index: Int, active: Bool) -> some View {
        modifier(CareStaggerAppear(index: index, active: active))
    }
}

// MARK: - Countdown ring

struct FollowUpCountdownRing: View {
    let date: Date
    var size: CGFloat = 52
    var lineWidth: CGFloat = 4

    private var progress: Double { FollowUpService.countdownProgress(for: date) }
    private var urgency: FollowUpUrgency { FollowUpService.urgencyLevel(for: date) }
    private var days: Int { FollowUpService.countdownDays(for: date) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(CareTheme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    urgency.tint,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.55, dampingFraction: 0.82), value: progress)
            VStack(spacing: 0) {
                if days >= 0 && days <= 30 {
                    Text("\(max(days, 0))")
                        .font(.system(size: size * 0.28, design: .rounded).weight(.bold))
                        .monospacedDigit()
                    Text("天")
                        .font(.system(size: size * 0.16, weight: .medium))
                } else if days < 0 {
                    Image(systemName: "exclamationmark")
                        .font(.caption.weight(.bold))
                } else {
                    Image(systemName: "calendar")
                        .font(.caption.weight(.semibold))
                }
            }
            .foregroundStyle(urgency.tint)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Badges & chips

struct FollowUpCountdownBadge: View {
    let text: String
    let urgency: FollowUpUrgency
    @State private var pulse = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(urgency.tint.opacity(pulse && isUrgent ? 0.22 : 0.14)))
            .foregroundStyle(urgency.tint)
            .scaleEffect(pulse && isUrgent ? 1.03 : 1)
            .animation(isUrgent ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear {
                pulse = isUrgent
            }
    }

    private var isUrgent: Bool {
        urgency == .today || urgency == .tomorrow
    }
}

struct FollowUpChipRow: View {
    let icon: String
    let tint: Color
    let items: [String]

    var body: some View {
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.caption2)
                        .foregroundStyle(tint)
                    ForEach(items, id: \.self) { item in
                        Text(item)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(tint.opacity(0.10)))
                    }
                }
            }
        }
    }
}

// MARK: - Hero & actions

struct FollowUpHeroBanner: View {
    let followUp: FollowUp

    private var urgency: FollowUpUrgency { FollowUpService.urgencyLevel(for: followUp.date) }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            FollowUpCountdownRing(date: followUp.date, size: 72, lineWidth: 5)
            VStack(alignment: .leading, spacing: 6) {
                FollowUpCountdownBadge(text: followUp.countdownText, urgency: urgency)
                Text(followUp.department)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                Text(followUp.date.formatted(date: .long, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                if !followUp.doctorName.isEmpty {
                    Label(followUp.doctorName, systemImage: "person.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: CareTheme.cardCornerRadius, style: .continuous)
                .fill(CareTheme.brandGradient)
                .shadow(color: CareTheme.sage.opacity(0.28), radius: 12, y: 5)
        )
    }
}

struct FollowUpPrimaryButton: View {
    let title: String
    let icon: String
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: icon)
                }
                Text(title)
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: CareTheme.smallCornerRadius, style: .continuous)
                    .fill(CareTheme.brandGradient)
                    .shadow(color: CareTheme.sage.opacity(0.25), radius: 8, y: 3)
            )
        }
        .buttonStyle(CareCardPressStyle())
        .disabled(isLoading)
    }
}

struct FollowUpInfoTile: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(CareTheme.muted)
                Text(value)
                    .font(CareTheme.body)
                    .foregroundStyle(CareTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FollowUpReportTile: View {
    let report: HospitalReport
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let image = PhotoStore.load(report.photoRef) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        } else {
                            CareTheme.track
                        }
                    }
                    .frame(height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? CareTheme.sage : .clear, lineWidth: 2.5)
                    }
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.body.weight(.semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(selected ? CareTheme.sage : .white, selected ? .white : Color.black.opacity(0.35))
                        .padding(7)
                        .scaleEffect(selected ? 1 : 0.92)
                        .animation(.spring(response: 0.32, dampingFraction: 0.65), value: selected)
                }
                Text(report.title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(CareTheme.ink)
            }
            .scaleEffect(selected ? 1.02 : 1)
            .animation(.spring(response: 0.35, dampingFraction: 0.78), value: selected)
        }
        .buttonStyle(CareCardPressStyle())
    }
}

struct FollowUpEmptyIllustration: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(CareTheme.sageSoft)
                .frame(width: 64, height: 64)
            Image(systemName: "calendar.badge.plus")
                .font(.title2)
                .foregroundStyle(CareTheme.sage)
                .symbolEffect(.bounce, value: true)
        }
    }
}

enum CareHaptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
