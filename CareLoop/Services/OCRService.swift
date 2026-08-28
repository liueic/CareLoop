import Foundation
import UIKit
import Vision

enum OCRService {
    static func recognize(image: UIImage) async -> String {
        guard let cg = image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        } catch {
            return ""
        }
    }

    static func parsePrescription(from text: String) -> DraftMedication? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let name = lines.first(where: { $0.count >= 2 && $0.count < 20 }) else { return nil }
        let dose = lines.first { $0.contains("mg") || $0.contains("毫克") || $0.contains("片") } ?? ""
        return DraftMedication(name: name, dose: dose, times: ["08:00"], cautions: text)
    }
}

struct DraftMedication: Hashable, Sendable {
    var name: String
    var dose: String
    var times: [String]
    var cautions: String
}
