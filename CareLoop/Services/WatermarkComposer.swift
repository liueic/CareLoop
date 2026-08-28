import UIKit

enum WatermarkComposer {
    static func compose(_ image: UIImage, snapshot: WatermarkSnapshot, includeSensitive: Bool) -> UIImage {
        let size = image.size
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            image.draw(in: CGRect(origin: .zero, size: size))
            let lines = snapshot.displayLines(includeSensitive: includeSensitive)
            let stamp = lines.first ?? snapshot.dateStamp
            drawStamp(stamp, in: ctx.cgContext, canvas: size)
            drawBar(Array(lines.dropFirst()), in: ctx.cgContext, canvas: size)
        }
    }

    private static func drawStamp(_ text: String, in _: CGContext, canvas: CGSize) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: max(14, canvas.width * 0.035), weight: .semibold),
            .foregroundColor: UIColor.white,
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let size = attributed.size()
        let origin = CGPoint(x: canvas.width * 0.04, y: canvas.height * 0.05)
        let bg = CGRect(x: origin.x - 8, y: origin.y - 6, width: size.width + 16, height: size.height + 12)
        UIColor.black.withAlphaComponent(0.35).setFill()
        UIBezierPath(roundedRect: bg, cornerRadius: 8).fill()
        attributed.draw(at: origin)
    }

    private static func drawBar(_ lines: [String], in _: CGContext, canvas: CGSize) {
        guard !lines.isEmpty else { return }
        let text = lines.joined(separator: "  ·  ")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: max(12, canvas.width * 0.028), weight: .medium),
            .foregroundColor: UIColor.white,
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let textSize = attributed.size()
        let barHeight = max(36, textSize.height + 20)
        let bar = CGRect(x: 0, y: canvas.height - barHeight, width: canvas.width, height: barHeight)
        UIColor.black.withAlphaComponent(0.42).setFill()
        UIBezierPath(rect: bar).fill()
        let origin = CGPoint(x: 16, y: canvas.height - barHeight + (barHeight - textSize.height) / 2)
        attributed.draw(at: origin)
    }
}

enum DemoPhoto {
    static func make() -> UIImage {
        let size = CGSize(width: 1200, height: 1600)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            UIColor(red: 0.45, green: 0.62, blue: 0.52, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
            UIColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 0.9).setFill()
            UIBezierPath(roundedRect: CGRect(x: 80, y: 520, width: 1040, height: 360), cornerRadius: 28).fill()
            let title = NSAttributedString(
                string: "演示手帐照片",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 48, weight: .semibold),
                    .foregroundColor: UIColor(red: 0.18, green: 0.42, blue: 0.35, alpha: 1),
                ]
            )
            title.draw(at: CGPoint(x: 140, y: 640))
            let subtitle = NSAttributedString(
                string: "模拟器无摄像头时用于走通水印流程",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 28, weight: .regular),
                    .foregroundColor: UIColor.darkGray,
                ]
            )
            subtitle.draw(at: CGPoint(x: 140, y: 720))
        }
    }
}
