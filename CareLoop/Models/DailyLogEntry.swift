import Foundation
import SwiftData

@Model
final class DailyLogEntry {
    var id: UUID
    var createdAt: Date
    var kindRaw: String
    var photoRef: String?
    var watermarkJSON: Data?
    var voiceMemoRef: String?
    var transcript: String
    var contentText: String
    var tags: [String]
    var symptomsJSON: Data?
    var structuredJSON: Data?
    var confirmationRaw: String
    var aiLabel: String?
    var aiExplanation: String?

    init(
        kind: LogKind,
        createdAt: Date = Date(),
        photoRef: String? = nil,
        watermark: WatermarkSnapshot? = nil,
        voiceMemoRef: String? = nil,
        transcript: String = "",
        contentText: String = "",
        tags: [String] = [],
        symptoms: [SymptomEntry] = [],
        structured: DailyStructuredFields? = nil,
        confirmation: ConfirmationState = .skipped
    ) {
        self.id = UUID()
        self.createdAt = createdAt
        self.kindRaw = kind.rawValue
        self.photoRef = photoRef
        self.watermarkJSON = try? JSONEncoder().encode(watermark)
        self.voiceMemoRef = voiceMemoRef
        self.transcript = transcript
        self.contentText = contentText
        self.tags = tags
        self.symptomsJSON = try? JSONEncoder().encode(symptoms)
        self.structuredJSON = try? JSONEncoder().encode(structured)
        self.confirmationRaw = confirmation.rawValue
    }

    var kind: LogKind {
        get { LogKind(rawValue: kindRaw) ?? .text }
        set { kindRaw = newValue.rawValue }
    }

    var confirmationState: ConfirmationState {
        get { ConfirmationState(rawValue: confirmationRaw) ?? .skipped }
        set { confirmationRaw = newValue.rawValue }
    }

    var watermarkSnapshot: WatermarkSnapshot? {
        get {
            guard let watermarkJSON else { return nil }
            return try? JSONDecoder().decode(WatermarkSnapshot.self, from: watermarkJSON)
        }
        set { watermarkJSON = try? JSONEncoder().encode(newValue) }
    }

    var symptoms: [SymptomEntry] {
        get {
            guard let symptomsJSON else { return [] }
            return (try? JSONDecoder().decode([SymptomEntry].self, from: symptomsJSON)) ?? []
        }
        set { symptomsJSON = try? JSONEncoder().encode(newValue) }
    }

    var structuredFields: DailyStructuredFields? {
        get {
            guard let structuredJSON else { return nil }
            return try? JSONDecoder().decode(DailyStructuredFields.self, from: structuredJSON)
        }
        set { structuredJSON = try? JSONEncoder().encode(newValue) }
    }

    var medicalDoc: MedicalDocResult? {
        structuredFields?.medicalDoc
    }

    var displayBody: String {
        if !contentText.isEmpty { return contentText }
        if !transcript.isEmpty { return transcript }
        if !symptoms.isEmpty {
            return symptoms.map { "\($0.name)·\($0.severity.rawValue)" }.joined(separator: "、")
        }
        if let doc = medicalDoc {
            let parts = [doc.title, doc.summary].compactMap { $0 }.filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: " — ") }
        }
        if let aiLabel { return aiLabel }
        return "一条手帐"
    }
}
