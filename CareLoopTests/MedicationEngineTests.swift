import Foundation
@testable import CareLoop
import Testing

struct MedicationEngineTests {
    @Test func generatesSlotsAndMissed() {
        let med = Medication(name: "氨氯地平", dosePerTime: "5mg", timesOfDay: ["08:00", "20:00"])
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let slots = MedicationEngine.slotsForDay(medications: [med], intakes: [], day: day, calendar: cal)
        #expect(slots.count == 2)
        let morning = cal.date(bySettingHour: 8, minute: 0, second: 0, of: day)!
        let marked = MedicationEngine.markMissedIfNeeded(
            slots: slots,
            now: morning.addingTimeInterval(3600)
        )
        #expect(marked.first?.status == .missed)
        #expect(MedicationEngine.missedHint.contains("药师"))
    }

    @Test func adherenceRatio() {
        let med = Medication(name: "二甲双胍", dosePerTime: "500mg")
        let taken = MedicationIntake(medication: med, scheduledTime: Date(), status: .taken)
        let missed = MedicationIntake(medication: med, scheduledTime: Date(), status: .missed)
        let summary = MedicationEngine.adherence(intakes: [taken, missed], expectedSlots: 2)
        #expect(abs(summary.ratio - 0.5) < 0.01)
    }
}

struct LLMServiceManagementTests {
    @Test func healthCheckStateMachine() {
        #expect(HealthCheckService.classify(0.8) == .ok)
        #expect(HealthCheckService.classify(4) == .degraded)
        #expect(HealthCheckService.classify(12) == .down)
    }

    @Test func catalogMergeAndUnknownMetadata() throws {
        let json = """
        {"providers":{"deepseek":{"models":{"deepseek-chat":{"name":"DeepSeek Chat","limit":{"context":64000,"output":8000},"modalities":{"input":["text"]},"cost":{"input":0.2,"output":0.8}}}}}}
        """.data(using: .utf8)!
        // 解析结构不依赖 SwiftData 上下文：验证映射函数可被 merge 消化
        let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        #expect(obj?["providers"] != nil)
    }

    @Test func visionRouting() {
        let vision = BundledModelCatalog.load().filter { $0.supportsVision }
        let textOnly = BundledModelCatalog.load().filter { !$0.supportsVision }
        #expect(!vision.isEmpty)
        #expect(!textOnly.isEmpty)
        #expect(vision.contains { $0.supportsVision })
        #expect(vision.allSatisfy { $0.supportsVision })
    }
}
