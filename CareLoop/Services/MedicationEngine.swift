import Foundation

struct MedicationSlot: Identifiable, Hashable, Sendable {
    var id: UUID
    var medicationID: UUID
    var name: String
    var dose: String
    var scheduledTime: Date
    var status: IntakeStatus
}

struct AdherenceSummary: Hashable, Sendable {
    var windowDays: Int
    var taken: Int
    var expected: Int

    var ratio: Double {
        guard expected > 0 else { return 1 }
        return Double(taken) / Double(expected)
    }

    var percentText: String {
        String(format: "%.0f%%", ratio * 100)
    }
}

enum MedicationEngine: Sendable {
    static func slotsForDay(
        medications: [Medication],
        intakes: [MedicationIntake],
        day: Date,
        calendar: Calendar = .current
    ) -> [MedicationSlot] {
        let start = calendar.startOfDay(for: day)
        var result: [MedicationSlot] = []
        for med in medications where med.isActive && med.confirmedByUser {
            for timeText in med.timesOfDay {
                guard let scheduled = combine(day: start, timeText: timeText, calendar: calendar) else { continue }
                let existing = intakes.first {
                    $0.medicationID == med.id && calendar.isDate($0.scheduledTime, equalTo: scheduled, toGranularity: .minute)
                }
                result.append(
                    MedicationSlot(
                        id: existing?.id ?? UUID(),
                        medicationID: med.id,
                        name: med.name,
                        dose: med.dosePerTime,
                        scheduledTime: scheduled,
                        status: existing?.status ?? .scheduled
                    )
                )
            }
        }
        return result.sorted { $0.scheduledTime < $1.scheduledTime }
    }

    static func markMissedIfNeeded(slots: [MedicationSlot], now: Date = Date()) -> [MedicationSlot] {
        slots.map { slot in
            var copy = slot
            if copy.status == .scheduled, copy.scheduledTime.addingTimeInterval(30 * 60) < now {
                copy.status = .missed
            }
            return copy
        }
    }

    static func adherence(
        intakes: [MedicationIntake],
        expectedSlots: Int,
        windowDays: Int = 7
    ) -> AdherenceSummary {
        let taken = intakes.filter { $0.status == .taken }.count
        return AdherenceSummary(windowDays: windowDays, taken: taken, expected: max(expectedSlots, intakes.count))
    }

    static let missedHint = "如有漏服，请按医嘱处理，或咨询医生/药师。应用不会给出剂量或补服建议。"

    private static func combine(day: Date, timeText: String, calendar: Calendar) -> Date? {
        let parts = timeText.split(separator: ":")
        guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }
}
