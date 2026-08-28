import Foundation
import SwiftData

@Model
final class HospitalReport {
    var id: UUID
    var title: String
    var capturedAt: Date
    var photoRef: String

    init(title: String = "医院报告", capturedAt: Date = Date(), photoRef: String) {
        self.id = UUID()
        self.title = title
        self.capturedAt = capturedAt
        self.photoRef = photoRef
    }
}
