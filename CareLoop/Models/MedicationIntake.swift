import Foundation
import SwiftData

@Model
final class MedicationIntake {
    var id: UUID
    var medicationID: UUID
    var medicationName: String
    var scheduledTime: Date
    var takenAt: Date?
    var statusRaw: String

    init(medication: Medication, scheduledTime: Date, status: IntakeStatus = .scheduled) {
        self.id = UUID()
        self.medicationID = medication.id
        self.medicationName = medication.name
        self.scheduledTime = scheduledTime
        self.statusRaw = status.rawValue
    }

    var status: IntakeStatus {
        get { IntakeStatus(rawValue: statusRaw) ?? .scheduled }
        set { statusRaw = newValue.rawValue }
    }
}
