import SwiftUI

/// 首屏：问候语 + 闭环图形 + 一个开始按钮。
struct WelcomeView: View {
    var skip: () -> Void
    var start: () -> Void

    @State private var breathe = false
    @State private var bounce = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Text("今天，")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(CareTheme.ink)
                Text("和身体聊聊天")
                    .font(.system(size: 40, weight: .medium, design: .rounded))
                    .foregroundStyle(CareTheme.sage)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .offset(y: breathe ? -2 : 2)
            .animation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true), value: breathe)

            Spacer()

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [CareTheme.sage.opacity(0.16), CareTheme.sage.opacity(0)],
                            center: .center,
                            startRadius: 10,
                            endRadius: 150
                        )
                    )
                    .frame(width: 300, height: 300)
                    .scaleEffect(breathe ? 1.06 : 0.96)

                CareLoopMark(size: 120)
                    .shadow(color: CareTheme.sage.opacity(0.25), radius: 18, y: 10)
            }

            Spacer()

            Button(action: start) {
                Text("开始吧 ✨")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(CareTheme.brandGradient)
                    )
                    .scaleEffect(bounce ? 1.03 : 1)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 28)
            .accessibilityIdentifier("onboarding.continue")

            Button(action: skip) {
                Text("稍后再说")
                    .font(.subheadline)
                    .foregroundStyle(CareTheme.muted)
                    .padding(.vertical, 14)
            }
            .accessibilityIdentifier("onboarding.skip")

            Text("你的数据，只属于你。本应用仅供参考。")
                .font(.caption2)
                .foregroundStyle(CareTheme.muted.opacity(0.7))
                .padding(.bottom, 18)
        }
        .onAppear {
            breathe = true
            withAnimation(.spring(response: 0.5, dampingFraction: 0.5).repeatForever(autoreverses: true)) {
                bounce = true
            }
        }
    }
}

/// 品牌图形：闭合圆环 + 中间小人伸手碰触圆环，象征闭环管理。
struct CareLoopMark: View {
    var size: CGFloat = 100

    var body: some View {
        Canvas { context, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let unit = canvasSize.width / 100

            // 闭合圆环
            let ringRect = CGRect(
                x: center.x - 40 * unit, y: center.y - 40 * unit,
                width: 80 * unit, height: 80 * unit
            )
            context.stroke(
                Path(ellipseIn: ringRect),
                with: .color(CareTheme.sage),
                style: StrokeStyle(lineWidth: 7 * unit, lineCap: .round)
            )

            // 小人：头
            let headRect = CGRect(
                x: center.x - 7 * unit, y: center.y - 20 * unit,
                width: 14 * unit, height: 14 * unit
            )
            context.fill(Path(ellipseIn: headRect), with: .color(CareTheme.sageBright))

            // 小人：身体与伸出的手臂
            var bodyPath = Path()
            bodyPath.move(to: CGPoint(x: center.x, y: center.y - 6 * unit))
            bodyPath.addQuadCurve(
                to: CGPoint(x: center.x - 2 * unit, y: center.y + 16 * unit),
                control: CGPoint(x: center.x + 2 * unit, y: center.y + 5 * unit)
            )
            bodyPath.move(to: CGPoint(x: center.x, y: center.y - 2 * unit))
            bodyPath.addQuadCurve(
                to: CGPoint(x: center.x + 26 * unit, y: center.y - 30 * unit),
                control: CGPoint(x: center.x + 14 * unit, y: center.y - 14 * unit)
            )
            context.stroke(
                bodyPath,
                with: .color(CareTheme.sageBright),
                style: StrokeStyle(lineWidth: 6 * unit, lineCap: .round)
            )

            // 碰触点
            let touchRect = CGRect(
                x: center.x + 24 * unit - 4 * unit, y: center.y - 32 * unit - 4 * unit,
                width: 8 * unit, height: 8 * unit
            )
            context.fill(Path(ellipseIn: touchRect), with: .color(CareTheme.warn))
        }
        .frame(width: size, height: size)
    }
}

/// 连接页：三枚状态胶囊 + 开始按钮，不出现系统授权词汇。
struct ConnectView: View {
    @Environment(AppEnvironment.self) private var env

    var start: () -> Void
    var skip: () -> Void

    @State private var connected = false
    @State private var requesting = false
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("连接你的身体数据")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(CareTheme.ink)
            Text("让每一天的变化，都被温柔地看见")
                .font(.subheadline)
                .foregroundStyle(CareTheme.muted)
                .padding(.top, 6)

            Spacer()

            HStack(spacing: 14) {
                metricCapsule(icon: "figure.walk", name: "步数", index: 0)
                metricCapsule(icon: "heart.fill", name: "心率", index: 1)
                metricCapsule(icon: "moon.fill", name: "睡眠", index: 2)
            }
            .padding(.vertical, 8)

            if !connected {
                Button {
                    Task {
                        requesting = true
                        try? await env.healthProvider.requestAuthorization()
                        _ = await NotificationService.requestAccess()
                        requesting = false
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                            connected = true
                        }
                    }
                } label: {
                    Text(requesting ? "连接中…" : "连接健康数据")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CareTheme.sage)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(CareTheme.sageSoft))
                }
                .buttonStyle(.plain)
                .disabled(requesting)
                .padding(.top, 6)
            }

            Spacer()

            Button(action: start) {
                Text("开始吧 ✨")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(CareTheme.brandGradient)
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 28)
            .accessibilityIdentifier("onboarding.continue")

            Button(action: skip) {
                Text("稍后再说")
                    .font(.subheadline)
                    .foregroundStyle(CareTheme.muted)
                    .padding(.vertical, 14)
            }
            .accessibilityIdentifier("onboarding.skip")

            Text("你的数据，只属于你。本应用仅供参考。")
                .font(.caption2)
                .foregroundStyle(CareTheme.muted.opacity(0.7))
                .padding(.bottom, 18)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                appeared = true
            }
        }
    }

    private func metricCapsule(icon: String, name: String, index: Int) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: 64, height: 64)
                    .shadow(color: CareTheme.ink.opacity(0.08), radius: 8, y: 3)
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(CareTheme.sage)
            }
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(connected ? CareTheme.sage : CareTheme.warn)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
            Text(name)
                .font(.caption.weight(.medium))
                .foregroundStyle(CareTheme.ink)
            Text(connected ? "已连接" : "待开启")
                .font(.caption2)
                .foregroundStyle(CareTheme.muted)
        }
        .offset(y: appeared ? 0 : 16)
        .opacity(appeared ? 1 : 0)
        .animation(
            .spring(response: 0.5, dampingFraction: 0.8).delay(Double(index) * 0.1),
            value: appeared
        )
    }
}
