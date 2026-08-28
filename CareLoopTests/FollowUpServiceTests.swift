import Foundation
@testable import CareLoop
import Testing

struct FollowUpServiceTests {
    @Test func nextFollowUpSkipsCompletedAndPast() {
        let past = FollowUp(
            mode: .doctorOrdered,
            date: Date().addingTimeInterval(-86400),
            department: "旧",
            confirmedByUser: true
        )
        let completed = FollowUp(
            mode: .doctorOrdered,
            date: Date().addingTimeInterval(86400 * 3),
            department: "已完成",
            confirmedByUser: true,
            completedAt: Date()
        )
        let upcoming = FollowUp(
            mode: .doctorOrdered,
            date: Date().addingTimeInterval(86400 * 5),
            department: "心内科",
            confirmedByUser: true
        )
        let later = FollowUp(
            mode: .doctorOrdered,
            date: Date().addingTimeInterval(86400 * 10),
            department: "内分泌",
            confirmedByUser: true
        )
        let next = FollowUpService.nextFollowUp(from: [past, completed, later, upcoming])
        #expect(next?.department == "心内科")
    }

    @Test func countdownTextLabels() {
        let today = Calendar.current.startOfDay(for: Date())
        #expect(FollowUpService.countdownText(for: today) == "今天")
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        #expect(FollowUpService.countdownText(for: tomorrow) == "明天")
        let inFive = Calendar.current.date(byAdding: .day, value: 5, to: today)!
        #expect(FollowUpService.countdownText(for: inFive) == "5 天后")
    }

    @Test func legacyPreparationsSplit() {
        let item = FollowUp(
            mode: .doctorOrdered,
            date: Date(),
            department: "心内科",
            preparations: ["空腹", "携带近期化验单"],
            confirmedByUser: true
        )
        #expect(item.effectiveRestrictions.contains("空腹"))
        #expect(item.effectiveMaterials.contains("携带近期化验单"))
    }
}
