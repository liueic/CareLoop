import Foundation
import SwiftData

/// 结构化文档（处方/病历 OCR 或 LLM 识别）→ `Medication` 表的统一写入：
/// 同名去重、频次与时间由 `PrescriptionParser` 推导、特殊医嘱并入注意事项。
/// `CameraCaptureView.saveMedicalDoc` 与 `PrescriptionReviewSheet` 共用，避免两处维护。
@MainActor
enum MedicationImporter {
    struct Outcome {
        var added: [Medication]
        var skippedNames: [String]
    }

    @discardableResult
    static func importMedications(
        from doc: MedicalDocResult,
        into context: ModelContext,
        source: MedicationSource
    ) -> Outcome {
        let existing = (try? context.fetch(FetchDescriptor<Medication>())) ?? []
        let prescribedDate = PrescriptionParser.parseDate(doc.takenAt)
        var added: [Medication] = []
        var skipped: [String] = []
        for ext in doc.medications {
            if ext.name.isEmpty
                || existing.contains(where: { $0.name == ext.name })
                || added.contains(where: { $0.name == ext.name }) {
                if !ext.name.isEmpty {
                    skipped.append(ext.name)
                }
                continue
            }
            let frequency = ext.frequencyPerDay
                ?? PrescriptionParser.frequencyPerDay(from: ext.frequency)
                ?? 1
            let times = ext.timesOfDay
                ?? PrescriptionParser.timesOfDay(frequency: frequency, sig: ext.frequency)
            var cautions = ext.cautions ?? ""
            if let special = PrescriptionParser.specialInstructions(from: ext.frequency) {
                cautions = cautions.isEmpty ? special : cautions + "；" + special
            }
            let med = Medication(
                name: ext.name,
                dosePerTime: ext.dose ?? "",
                frequencyPerDay: frequency,
                timesOfDay: times,
                periodText: PrescriptionParser.periodText(from: ext.durationText) ?? "长期",
                cautions: cautions,
                source: source,
                prescribedDate: prescribedDate
            )
            context.insert(med)
            added.append(med)
        }
        return Outcome(added: added, skippedNames: skipped)
    }
}
