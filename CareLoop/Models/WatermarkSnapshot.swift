import Foundation

struct WatermarkSnapshot: Codable, Hashable, Sendable {
    var capturedAt: Date
    var weekday: String
    var sleepHours: Double?
    var restingHeartRate: Double?
    var currentHeartRate: Double?
    var steps: Double?
    var bloodPressureSystolic: Double?
    var bloodPressureDiastolic: Double?
    var bloodGlucose: Double?
    var sourceName: String
    var weatherText: String?
    var locationText: String?

    var dateStamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE HH:mm"
        return formatter.string(from: capturedAt)
    }

    func displayLines(includeSensitive: Bool) -> [String] {
        var lines: [String] = [dateStamp]
        if let sleepHours {
            lines.append(String(format: "睡眠 %.1f 小时", sleepHours))
        }
        if let restingHeartRate {
            lines.append(String(format: "静息心率 %.0f", restingHeartRate))
        }
        if let currentHeartRate {
            lines.append(String(format: "心率 %.0f", currentHeartRate))
        }
        if let steps {
            lines.append(String(format: "步数 %.0f", steps))
        }
        if includeSensitive {
            if let s = bloodPressureSystolic, let d = bloodPressureDiastolic {
                lines.append(String(format: "血压 %.0f/%.0f", s, d))
            }
            if let bloodGlucose {
                lines.append(String(format: "血糖 %.1f", bloodGlucose))
            }
        }
        if let weatherText, !weatherText.isEmpty {
            lines.append(weatherText)
        }
        if let locationText, !locationText.isEmpty {
            lines.append(locationText)
        }
        return lines
    }
}
