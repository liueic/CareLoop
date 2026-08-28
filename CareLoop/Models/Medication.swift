import Foundation
import SwiftData

@Model
final class Medication {
    var id: UUID
    var name: String
    var dosePerTime: String
    var frequencyPerDay: Int
    var timesOfDay: [String]
    var periodText: String
    var cautions: String
    var sourceRaw: String
    var prescribedDate: Date?
    var confirmedByUser: Bool
    var isActive: Bool

    init(
        name: String,
        dosePerTime: String,
        frequencyPerDay: Int = 1,
        timesOfDay: [String] = ["08:00"],
        periodText: String = "长期",
        cautions: String = "",
        source: MedicationSource = .manual,
        prescribedDate: Date? = nil,
        confirmedByUser: Bool = true
    ) {
        self.id = UUID()
        self.name = name
        self.dosePerTime = dosePerTime
        self.frequencyPerDay = frequencyPerDay
        self.timesOfDay = timesOfDay
        self.periodText = periodText
        self.cautions = cautions
        self.sourceRaw = source.rawValue
        self.prescribedDate = prescribedDate
        self.confirmedByUser = confirmedByUser
        self.isActive = true
    }

    var source: MedicationSource {
        get { MedicationSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }
}
