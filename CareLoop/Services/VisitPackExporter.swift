import Foundation
import UIKit

struct VisitPackInput {
    var followUp: FollowUp?
    var profile: UserProfile
    var medications: [Medication]
    var alerts: [AlertRecord]
    var adherence: AdherenceSummary
    var logs: [DailyLogEntry]
    var reports: [HospitalReport]
}

enum VisitPackExporter {
    private static let sage = UIColor(red: 0.18, green: 0.42, blue: 0.35, alpha: 1)
    private static let footerHeight: CGFloat = 28

    static func makePDF(_ input: VisitPackInput, exportedAt: Date = Date()) throws -> URL {
        let pageWidth: CGFloat = 595
        let pageHeight: CGFloat = 842
        let margin: CGFloat = 40
        let contentWidth = pageWidth - margin * 2
        let contentBottom = pageHeight - margin - footerHeight
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CareLoop-VisitPack-\(UUID().uuidString).pdf")

        try renderer.writePDF(to: url) { context in
            var pageNumber = 0
            var y = margin

            func drawPageChrome() {
                drawWatermark(pageWidth: pageWidth, pageHeight: pageHeight)
                drawFooter(
                    pageWidth: pageWidth,
                    pageHeight: pageHeight,
                    margin: margin,
                    exportedAt: exportedAt,
                    pageNumber: pageNumber
                )
            }

            func beginNewPage() {
                context.beginPage()
                pageNumber += 1
                drawPageChrome()
                y = margin
            }

            func newPageIfNeeded(_ needed: CGFloat) {
                if y + needed > contentBottom {
                    beginNewPage()
                }
            }

            func drawCoverTitle() {
                newPageIfNeeded(80)
                let titleAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 22),
                    .foregroundColor: UIColor.black,
                ]
                ("CareLoop 就诊材料" as NSString).draw(
                    in: CGRect(x: margin, y: y, width: contentWidth, height: 28),
                    withAttributes: titleAttrs
                )
                y += 34
                let brandAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: sage.withAlphaComponent(0.75),
                ]
                (VisitPackContentBuilder.exportBrand as NSString).draw(
                    in: CGRect(x: margin, y: y, width: contentWidth, height: 16),
                    withAttributes: brandAttrs
                )
                y += 22
            }

            func drawSection(_ title: String, body: String) {
                newPageIfNeeded(44)
                let titleAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 14),
                    .foregroundColor: sage,
                ]
                (title as NSString).draw(
                    in: CGRect(x: margin, y: y, width: contentWidth, height: 18),
                    withAttributes: titleAttrs
                )
                y += 22
                let bodyAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 11.5),
                    .foregroundColor: UIColor.black,
                ]
                let bounding = (body as NSString).boundingRect(
                    with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: bodyAttrs,
                    context: nil
                )
                newPageIfNeeded(bounding.height + 10)
                (body as NSString).draw(
                    in: CGRect(x: margin, y: y, width: contentWidth, height: bounding.height),
                    withAttributes: bodyAttrs
                )
                y += bounding.height + 18
            }

            func drawImage(_ image: UIImage, caption: String, maxHeight: CGFloat = 340) {
                let aspect = image.size.width / max(image.size.height, 1)
                var drawHeight = min(maxHeight, contentWidth / aspect)
                var drawWidth = drawHeight * aspect
                if drawWidth > contentWidth {
                    drawWidth = contentWidth
                    drawHeight = drawWidth / aspect
                }
                newPageIfNeeded(drawHeight + 36)
                let imageRect = CGRect(x: margin, y: y, width: drawWidth, height: drawHeight)
                image.draw(in: imageRect)
                drawImageWatermark(in: imageRect)
                y += drawHeight + 6
                if !caption.isEmpty {
                    let capAttrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 10),
                        .foregroundColor: UIColor.darkGray,
                    ]
                    (caption as NSString).draw(
                        in: CGRect(x: margin, y: y, width: contentWidth, height: 14),
                        withAttributes: capAttrs
                    )
                    y += 18
                }
            }

            beginNewPage()
            drawCoverTitle()
            for section in VisitPackContentBuilder.buildSections(input) {
                drawSection(section.title, body: section.body)
            }

            if !input.reports.isEmpty {
                drawSection("附：医院报告照片", body: "共 \(input.reports.count) 张")
                for report in input.reports {
                    if let image = PhotoStore.load(report.photoRef) {
                        let caption = "\(report.title) · \(report.capturedAt.formatted(date: .abbreviated, time: .omitted))"
                        drawImage(image, caption: caption)
                    }
                }
            }
        }
        return url
    }

    static func makePlainText(_ input: VisitPackInput) -> String {
        VisitPackContentBuilder.plainText(input)
    }

    // MARK: - Watermark

    private static func drawWatermark(pageWidth: CGFloat, pageHeight: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.translateBy(x: pageWidth * 0.5, y: pageHeight * 0.52)
        ctx.rotate(by: -.pi / 7)
        let text = VisitPackContentBuilder.exportBrand
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 42, weight: .semibold),
            .foregroundColor: sage.withAlphaComponent(0.07),
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: CGPoint(x: -size.width * 0.5, y: -size.height * 0.5),
            withAttributes: attrs
        )
        ctx.restoreGState()
    }

    private static func drawImageWatermark(in rect: CGRect) {
        let text = VisitPackContentBuilder.exportBrand
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.92),
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 6
        let bgRect = CGRect(
            x: rect.maxX - size.width - pad * 2 - 4,
            y: rect.maxY - size.height - pad * 2 - 4,
            width: size.width + pad * 2,
            height: size.height + pad * 2
        )
        let path = UIBezierPath(roundedRect: bgRect, cornerRadius: 4)
        sage.withAlphaComponent(0.72).setFill()
        path.fill()
        (text as NSString).draw(
            at: CGPoint(x: bgRect.minX + pad, y: bgRect.minY + pad),
            withAttributes: attrs
        )
    }

    private static func drawFooter(
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        margin: CGFloat,
        exportedAt: Date,
        pageNumber: Int
    ) {
        let lineY = pageHeight - margin - footerHeight + 4
        let line = UIBezierPath()
        line.move(to: CGPoint(x: margin, y: lineY))
        line.addLine(to: CGPoint(x: pageWidth - margin, y: lineY))
        UIColor(white: 0.85, alpha: 1).setStroke()
        line.lineWidth = 0.5
        line.stroke()

        let left = "\(VisitPackContentBuilder.exportBrand) · \(exportedAt.formatted(date: .abbreviated, time: .shortened))"
        let right = "第 \(pageNumber) 页"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor.gray,
        ]
        (left as NSString).draw(
            in: CGRect(x: margin, y: lineY + 6, width: pageWidth * 0.72, height: 14),
            withAttributes: attrs
        )
        let rightSize = (right as NSString).size(withAttributes: attrs)
        (right as NSString).draw(
            at: CGPoint(x: pageWidth - margin - rightSize.width, y: lineY + 6),
            withAttributes: attrs
        )
    }
}
