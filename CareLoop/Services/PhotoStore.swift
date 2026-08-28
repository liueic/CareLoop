import Foundation
import UIKit

enum PhotoStore {
    static var directory: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func saveJPEG(_ image: UIImage, quality: CGFloat = 0.85) throws -> String {
        let name = "\(UUID().uuidString).jpg"
        guard let data = image.jpegData(compressionQuality: quality) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return name
    }

    static func load(_ ref: String) -> UIImage? {
        let url = directory.appendingPathComponent(ref)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func audioDirectory() -> URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
