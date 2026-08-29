import Foundation
import SwiftData
import Testing

@testable import CareLoop

/// 结构化处方 → Medication 落库：同名去重、频次/时间推导、疗程与特殊医嘱。
struct MedicationImporterTests {
    @MainActor
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Medication.self, configurations: config)
        return ModelContext(container)
    }

    private func makeDoc(meds: [ExtractedMedication], takenAt: String? = "2026-08-01") -> MedicalDocResult {
        MedicalDocResult(
            docType: "处方单",
            title: nil,
            takenAt: takenAt,
            diagnoses: [],
            labValues: [],
            medications: meds,
            recommendations: [],
            followUpHint: nil,
            followUpDate: nil,
            followUpDepartment: nil,
            summary: "测试处方"
        )
    }

    @Test
    @MainActor
    func skipsExistingAndNewDuplicates() throws {
        let context = try makeContext()
        context.insert(Medication(name: "氨氯地平", dosePerTime: "5mg"))

        let outcome = MedicationImporter.importMedications(
            from: makeDoc(meds: [
                ExtractedMedication(
                    name: "氨氯地平", dose: "5mg", frequency: "每日1次", timesOfDay: nil,
                    frequencyPerDay: 1, cautions: nil
                ),
                ExtractedMedication(
                    name: "二甲双胍", dose: "500mg", frequency: "每日2次", timesOfDay: nil,
                    frequencyPerDay: 2, cautions: "随餐"
                ),
                // 同一张处方里重复出现的药也只导入一次
                ExtractedMedication(
                    name: "二甲双胍", dose: "500mg", frequency: nil, timesOfDay: nil,
                    frequencyPerDay: nil, cautions: nil
                ),
            ]),
            into: context,
            source: .prescriptionOCR
        )

        #expect(outcome.added.map(\.name) == ["二甲双胍"])
        #expect(outcome.skippedNames == ["氨氯地平", "二甲双胍"])
        let all = try context.fetch(FetchDescriptor<Medication>())
        #expect(all.count == 2)
    }

    @Test
    @MainActor
    func frequencyFallbackAndTimeInference() throws {
        let context = try makeContext()
        var ext = ExtractedMedication(
            name: "阿卡波糖", dose: nil, frequency: "每日3次，每次1片，餐前", timesOfDay: nil,
            frequencyPerDay: nil, cautions: nil
        )
        ext.dose = PrescriptionParser.dosePerTake(from: ext.frequency)

        MedicationImporter.importMedications(
            from: makeDoc(meds: [ext]),
            into: context,
            source: .prescriptionOCR
        )

        let med = try #require(try context.fetch(FetchDescriptor<Medication>()).first)
        #expect(med.frequencyPerDay == 3)
        #expect(med.timesOfDay == ["07:00", "11:00", "17:00"])
        #expect(med.dosePerTime == "1片")
        #expect(med.source == .prescriptionOCR)
        #expect(med.confirmedByUser)
    }

    @Test
    @MainActor
    func durationAndSpecialInstructions() throws {
        let context = try makeContext()
        var ext = ExtractedMedication(
            name: "阿莫西林", dose: "1粒", frequency: "隔日一次", timesOfDay: nil,
            frequencyPerDay: nil, cautions: nil
        )
        ext.durationText = "两周"

        MedicationImporter.importMedications(
            from: makeDoc(meds: [ext], takenAt: "2026-07-15"),
            into: context,
            source: .medicalDocOCR
        )

        let med = try #require(try context.fetch(FetchDescriptor<Medication>()).first)
        #expect(med.periodText == "两周")
        #expect(med.cautions.contains("隔日服用一次"))
        #expect(med.source == .medicalDocOCR)
        let components = Calendar.current.dateComponents([.year, .month, .day], from: med.prescribedDate ?? Date())
        #expect(components == DateComponents(year: 2026, month: 7, day: 15))
    }

    @Test
    @MainActor
    func defaultsWhenSparse() throws {
        let context = try makeContext()
        let ext = ExtractedMedication(
            name: "未知药品", dose: nil, frequency: nil, timesOfDay: nil,
            frequencyPerDay: nil, cautions: nil
        )
        MedicationImporter.importMedications(
            from: makeDoc(meds: [ext], takenAt: nil),
            into: context,
            source: .prescriptionOCR
        )
        let med = try #require(try context.fetch(FetchDescriptor<Medication>()).first)
        #expect(med.frequencyPerDay == 1)
        #expect(med.timesOfDay == ["08:00"])
        #expect(med.periodText == "长期")
        #expect(med.prescribedDate == nil)
    }
}
