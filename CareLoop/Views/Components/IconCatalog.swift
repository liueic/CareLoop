import SwiftUI

/// 全局统一的 SF Symbol 与配色映射，避免各页面各自为政。
enum IconCatalog {
    static func icon(for kind: LogKind) -> String {
        switch kind {
        case .photo: "camera.fill"
        case .voice: "waveform"
        case .text: "text.alignleft"
        case .quickTag: "tag.fill"
        case .symptom: "waveform.path.ecg"
        case .medicalDoc: "doc.text.magnifyingglass"
        }
    }

    static func icon(for type: MetricType) -> String {
        switch type {
        case .stepCount: "figure.walk"
        case .restingHeartRate, .heartRate: "heart.fill"
        case .hrvSDNN: "waveform.path.ecg"
        case .activeEnergy: "flame.fill"
        case .sleepHours: "moon.zzz.fill"
        case .bodyMass: "scalemass.fill"
        case .bloodPressureSystolic, .bloodPressureDiastolic: "stethoscope"
        case .bloodGlucose: "drop.fill"
        case .oxygenSaturation: "lungs.fill"
        case .workoutMinutes: "figure.run"
        case .vo2max: "wind"
        case .respiratoryRate: "lungs.fill"
        case .wristTemperatureDeviation: "thermometer.medium"
        case .cgmTIR, .cgmMean, .hba1c: "drop.fill"
        case .sleepDeepPercent, .sleepREMPercent: "moon.zzz.fill"
        case .afBurden: "waveform.path.ecg"
        case .totalCholesterol, .ldlCholesterol, .hdlCholesterol, .triglycerides: "drop.triangle.fill"
        case .waistCircumference: "figure.stand"
        }
    }

    static func color(for type: MetricType) -> Color {
        switch type {
        case .stepCount, .workoutMinutes, .activeEnergy: CareTheme.sage
        case .restingHeartRate, .heartRate, .hrvSDNN: CareTheme.danger
        case .sleepHours: Color(red: 0.38, green: 0.36, blue: 0.62)
        case .bloodPressureSystolic, .bloodPressureDiastolic: Color(red: 0.60, green: 0.30, blue: 0.50)
        case .bloodGlucose, .cgmTIR, .cgmMean, .hba1c: Color(red: 0.72, green: 0.48, blue: 0.16)
        case .bodyMass, .oxygenSaturation, .respiratoryRate, .waistCircumference: CareTheme.muted
        case .vo2max, .wristTemperatureDeviation: CareTheme.sage
        case .sleepDeepPercent, .sleepREMPercent: Color(red: 0.38, green: 0.36, blue: 0.62)
        case .afBurden: CareTheme.danger
        case .totalCholesterol, .ldlCholesterol, .hdlCholesterol, .triglycerides:
            Color(red: 0.60, green: 0.30, blue: 0.50)
        }
    }

    static func color(forTag tag: String) -> Color {
        switch LogTag(rawValue: tag) {
        case .diet: Color(red: 0.80, green: 0.45, blue: 0.18)
        case .exercise: CareTheme.sage
        case .sleep: Color(red: 0.38, green: 0.36, blue: 0.62)
        case .mood: Color(red: 0.82, green: 0.45, blue: 0.55)
        case .alcohol: Color(red: 0.55, green: 0.35, blue: 0.65)
        case .caffeine: Color(red: 0.50, green: 0.36, blue: 0.25)
        case .symptom: CareTheme.danger
        case nil: CareTheme.muted
        }
    }
}
