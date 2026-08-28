import Foundation
@testable import CareLoop
import Testing

struct VisitPackContentBuilderTests {
    @Test func exportSectionsIncludeProfileAndBrand() {
        let profile = UserProfile()
        profile.conditions = ["高血压"]
        profile.drugAllergies = ["青霉素"]
        let sections = VisitPackContentBuilder.buildSections(
            VisitPackInput(
                followUp: FollowUp(
                    mode: .doctorOrdered,
                    date: Date(),
                    department: "心内科",
                    doctorName: "王医生",
                    preVisitRestrictions: ["空腹"],
                    materialsToBring: ["化验单"],
                    confirmedByUser: true
                ),
                profile: profile,
                medications: [
                    Medication(name: "氨氯地平", dosePerTime: "5mg", timesOfDay: ["08:00"])
                ],
                alerts: [],
                adherence: AdherenceSummary(windowDays: 7, taken: 6, expected: 7),
                logs: [],
                reports: []
            )
        )
        let titles = Set(sections.map(\.title))
        #expect(titles.contains("健康画像"))
        #expect(titles.contains("复诊安排"))
        #expect(titles.contains("当前用药清单"))
        let plain = VisitPackContentBuilder.plainText(
            VisitPackInput(
                followUp: nil,
                profile: profile,
                medications: [],
                alerts: [],
                adherence: AdherenceSummary(windowDays: 7, taken: 0, expected: 0),
                logs: [],
                reports: []
            )
        )
        #expect(plain.contains("Exported by CareLoop"))
        #expect(!plain.contains("不构成医疗建议"))
    }
}
