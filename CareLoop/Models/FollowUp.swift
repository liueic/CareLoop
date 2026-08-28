import Foundation
import SwiftData

@Model
final class FollowUp {
    var id: UUID
    var modeRaw: String
    var date: Date
    var department: String
    var doctorName: String = ""
    var hospital: String = ""
    var preVisitRestrictions: [String] = []
    var materialsToBring: [String] = []
    /// Legacy field kept for migration from older builds.
    var preparations: [String]
    var notes: String
    var confirmedByUser: Bool
    var completedAt: Date?

    init(
        mode: FollowUpMode,
        date: Date,
        department: String,
        doctorName: String = "",
        hospital: String = "",
        preVisitRestrictions: [String] = [],
        materialsToBring: [String] = [],
        preparations: [String] = [],
        notes: String = "",
        confirmedByUser: Bool = false,
        completedAt: Date? = nil
    ) {
        self.id = UUID()
        self.modeRaw = mode.rawValue
        self.date = date
        self.department = department
        self.doctorName = doctorName
        self.hospital = hospital
        self.preVisitRestrictions = preVisitRestrictions
        self.materialsToBring = materialsToBring
        self.preparations = preparations
        self.notes = notes
        self.confirmedByUser = confirmedByUser
        self.completedAt = completedAt
    }

    var mode: FollowUpMode {
        get { FollowUpMode(rawValue: modeRaw) ?? .doctorOrdered }
        set { modeRaw = newValue.rawValue }
    }

    var isCompleted: Bool { completedAt != nil }

    /// Restrictions for display, falling back to legacy `preparations`.
    var effectiveRestrictions: [String] {
        if !preVisitRestrictions.isEmpty { return preVisitRestrictions }
        return preparations.filter { !$0.contains("携带") }
    }

    /// Materials to bring, falling back to legacy `preparations`.
    var effectiveMaterials: [String] {
        if !materialsToBring.isEmpty { return materialsToBring }
        return preparations.filter { $0.contains("携带") || $0.contains("化验") || $0.contains("清单") || $0.contains("报告") }
    }

    var countdownText: String {
        FollowUpService.countdownText(for: date)
    }
}
