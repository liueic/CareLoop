import Foundation

enum SmartFollowUpEngine: Sendable {
    /// P1：给出“建议复查/建议咨询医生时间”，不表述为必须体检时间。
    static func suggestDate(
        from now: Date = Date(),
        hasPersistentAlert: Bool,
        calendar: Calendar = .current
    ) -> Date? {
        guard hasPersistentAlert else { return nil }
        return calendar.date(byAdding: .day, value: 14, to: now)
    }

    static let wording = "建议复查/建议咨询医生时间。这不是 AI 预测的必须体检时间。"
}
