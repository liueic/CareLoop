import Foundation
import SwiftData

@Model
final class FollowUp {
    var id: UUID
    var modeRaw: String
    var date: Date
    var department: String
    var preparations: [String]
    var notes: String
    var confirmedByUser: Bool

    init(
        mode: FollowUpMode,
        date: Date,
        department: String,
        preparations: [String] = [],
        notes: String = "",
        confirmedByUser: Bool = false
    ) {
        self.id = UUID()
        self.modeRaw = mode.rawValue
        self.date = date
        self.department = department
        self.preparations = preparations
        self.notes = notes
        self.confirmedByUser = confirmedByUser
    }

    var mode: FollowUpMode {
        get { FollowUpMode(rawValue: modeRaw) ?? .doctorOrdered }
        set { modeRaw = newValue.rawValue }
    }
}
