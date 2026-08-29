import Foundation

/// 血糖日聚合器（纯函数，输入统一为 mmol/L，可单测）。
///
/// CGM（动态血糖仪，如 Dexcom/Libre 同步）每天有几十到上百条读数；
/// 指尖血手动测量通常每天 ≤ 7 条。用密度护栏区分二者：
/// 样本不足时返回 nil，避免用两三个空腹值算出误导性的 TIR/均值。
enum GlucoseAggregator {
    /// 典型 CGM 为 15 分钟间隔（96 条/日），指尖血 ≤ 7 条/日；8 取两者之间的保守下界。
    static let minimumSamplesForCGMDay = 8
    /// 临床标准 TIR 区间 70–180 mg/dL，换算为 mmol/L。
    static let tirLowerBoundMmolL = 3.9
    static let tirUpperBoundMmolL = 10.0

    struct Summary: Equatable, Sendable {
        /// 处于 3.9–10.0 mmol/L（含边界）的读数百分比。
        var tirPercent: Double
        /// 全天读数均值（mmol/L）。
        var meanMmolL: Double
        var sampleCount: Int
    }

    static func evaluate(valuesMmolL: [Double]) -> Summary? {
        guard valuesMmolL.count >= minimumSamplesForCGMDay else { return nil }
        let inRange = valuesMmolL.filter { $0 >= tirLowerBoundMmolL && $0 <= tirUpperBoundMmolL }
        let mean = valuesMmolL.reduce(0, +) / Double(valuesMmolL.count)
        return Summary(
            tirPercent: Double(inRange.count) / Double(valuesMmolL.count) * 100,
            meanMmolL: mean,
            sampleCount: valuesMmolL.count
        )
    }
}
