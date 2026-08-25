import AppKit
import CoreGraphics
import CoreText

/// Renders a session into a single PDF with all images embedded – the
/// "one file to hand over" alternative to notes.md + PNG folder.
enum ScreenshotPDFExporter {

    // A4 portrait in points
    private static let pageSize = CGSize(width: 595.28, height: 841.89)
    private static let margin: CGFloat = 48
    private static var contentWidth: CGFloat { pageSize.width - margin * 2 }

    static func pdfData(for session: ScreenshotSession, folder: URL) -> Data? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let info: [CFString: Any] = [
            kCGPDFContextTitle: title.isEmpty ? "Screenshot Notes" : title,
            kCGPDFContextCreator: "AIHelper"
        ]
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else { return nil }

        var writer = PageWriter(context: context)
        writer.beginPage()

        // Title block
        writer.draw(text: styled(title.isEmpty ? "Screenshot Notes" : title, style: .title))
        writer.space(6)
        var meta = "Session started \(ScreenshotMarkdownExporter.dateTime(session.startedAt)) · \(session.captures.count) screenshot\(session.captures.count == 1 ? "" : "s")"
        meta += "\nFolder: \(folder.path)"
        writer.draw(text: styled(meta, style: .meta))
        writer.space(10)
        let task = session.task.trimmingCharacters(in: .whitespacesAndNewlines)
        if !task.isEmpty {
            writer.draw(text: styled("Task for the agent", style: .subheading))
            writer.space(3)
            writer.draw(text: styled(task, style: .body))
            writer.space(10)
        }
        writer.draw(text: styled(
            "Red numbered markers in each screenshot correspond to the numbered areas listed below it. Crops show just the marked part of the page.",
            style: .body
        ))

        let sorted = session.captures.sorted { $0.index < $1.index }
        for (offset, capture) in sorted.enumerated() {
            if offset == 0 {
                // First screenshot shares the page with the title block
                writer.space(18)
            } else {
                writer.beginPage()
            }
            drawCapture(capture, folder: folder, writer: &writer)
        }

        writer.finish()
        return data as Data
    }

    // MARK: - Capture layout

    private static func drawCapture(_ capture: ScreenshotCapture, folder: URL, writer: inout PageWriter) {
        writer.draw(text: styled("\(capture.index). \(capture.displayTitle)", style: .heading))
        writer.space(4)

        var metaLines: [String] = []
        if let url = capture.pageURL, !url.isEmpty { metaLines.append(url) }
        var details: [String] = []
        if let app = capture.appName, !app.isEmpty { details.append(app) }
        details.append(ScreenshotMarkdownExporter.dateTime(capture.date))
        details.append("\(capture.pixelWidth)×\(capture.pixelHeight) px")
        metaLines.append(details.joined(separator: " · "))
        writer.draw(text: styled(metaLines.joined(separator: "\n"), style: .meta))
        writer.space(10)

        let primaryName = capture.annotatedFileName ?? capture.imageFileName
        if let image = loadImage(folder.appendingPathComponent(primaryName)) {
            writer.draw(image: image, maxHeight: pageSize.height * 0.55)
            writer.space(12)
        } else {
            writer.draw(text: styled("(image missing: \(primaryName))", style: .meta))
            writer.space(8)
        }

        let general = capture.generalNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !general.isEmpty {
            writer.draw(text: styled("Notes", style: .subheading))
            writer.space(3)
            writer.draw(text: styled(general, style: .body))
            writer.space(12)
        }

        guard !capture.regions.isEmpty else { return }
        writer.draw(text: styled("Marked areas", style: .subheading))
        writer.space(6)

        for (offset, region) in capture.regions.enumerated() {
            let number = offset + 1
            let note = region.note.trimmingCharacters(in: .whitespacesAndNewlines)
            let px = region.pixelRect(in: capture.pixelSize)
            let position = "x=\(Int(px.origin.x)), y=\(Int(px.origin.y)), \(Int(px.width))×\(Int(px.height)) px"

            let cropURL = folder.appendingPathComponent(capture.regionFileName(number: number))
            let crop = loadImage(cropURL)
            let cropMaxHeight: CGFloat = 180
            let cropMaxWidth = contentWidth * 0.7

            // Keep title, a few lines of note and the crop together when they fit on one page
            var blockEstimate: CGFloat = 70
            if let crop {
                let scale = min(cropMaxWidth / CGFloat(crop.width), cropMaxHeight / CGFloat(crop.height), 1)
                blockEstimate += CGFloat(crop.height) * scale + 8
            }
            writer.keepTogether(minHeight: min(blockEstimate, 320))

            writer.draw(text: styled("Area \(number)", style: .areaTitle), badge: number)
            writer.draw(text: styled(position, style: .meta))
            writer.space(3)
            writer.draw(text: styled(note.isEmpty ? "(no note)" : note, style: .body))
            writer.space(4)

            if let crop {
                writer.draw(image: crop, maxHeight: cropMaxHeight, maxWidth: cropMaxWidth)
            }
            writer.space(14)
        }
    }

    /// Longest side of images inside the PDF – plenty for reading, small on disk.
    private static let pdfImageMaxDimension: CGFloat = 2000
    private static let pdfJPEGQuality: CGFloat = 0.8

    /// Loads an image and re-wraps it as JPEG-backed CGImage: Quartz then embeds
    /// the JPEG bytes as-is (DCTDecode) instead of a lossless bitmap, which is
    /// what keeps the PDF small.
    private static func loadImage(_ url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url),
              let decoded = ScreenshotImageRenderer.cgImage(fromPNG: data) else { return nil }
        let scaled = ScreenshotImageRenderer.downscaled(decoded, maxDimension: pdfImageMaxDimension)
        guard let jpeg = ScreenshotImageRenderer.jpegData(from: scaled, quality: pdfJPEGQuality),
              let provider = CGDataProvider(data: jpeg as CFData),
              let wrapped = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return scaled }
        return wrapped
    }

    // MARK: - Text styles

    private enum TextStyle {
        case title, heading, subheading, areaTitle, body, meta
    }

    private static func styled(_ text: String, style: TextStyle) -> NSAttributedString {
        let font: NSFont
        let color: NSColor
        switch style {
        case .title:
            font = .boldSystemFont(ofSize: 22); color = .black
        case .heading:
            font = .boldSystemFont(ofSize: 16); color = .black
        case .subheading:
            font = .boldSystemFont(ofSize: 12); color = .black
        case .areaTitle:
            font = .boldSystemFont(ofSize: 11); color = .black
        case .body:
            font = .systemFont(ofSize: 10.5); color = .black
        case .meta:
            font = .systemFont(ofSize: 9); color = NSColor(white: 0.4, alpha: 1)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
    }

    // MARK: - Page writer

    /// Tracks a top-down cursor on the current PDF page and paginates text/images.
    private struct PageWriter {
        let context: CGContext
        private(set) var pageNumber = 0
        private var cursorY: CGFloat = 0   // distance from top of page
        private var pageOpen = false

        init(context: CGContext) {
            self.context = context
        }

        private var remaining: CGFloat {
            pageSize.height - margin - cursorY
        }

        mutating func beginPage() {
            if pageOpen { endPage() }
            pageNumber += 1
            context.beginPDFPage(nil)
            pageOpen = true
            cursorY = margin
            drawFooter()
        }

        private mutating func endPage() {
            context.endPDFPage()
            pageOpen = false
        }

        mutating func finish() {
            if pageOpen { endPage() }
            context.closePDF()
        }

        private func drawFooter() {
            let text = styled("AIHelper Screenshot Notes · page \(pageNumber)", style: .meta)
            let line = CTLineCreateWithAttributedString(text)
            let bounds = CTLineGetBoundsWithOptions(line, [])
            context.saveGState()
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: pageSize.width - margin - bounds.width, y: margin * 0.5)
            CTLineDraw(line, context)
            context.restoreGState()
        }

        mutating func space(_ points: CGFloat) {
            cursorY += points
        }

        /// Starts a new page if less than `minHeight` is left, so a small
        /// block (area title + note start) does not get orphaned.
        mutating func keepTogether(minHeight: CGFloat) {
            if remaining < minHeight { beginPage() }
        }

        /// Draws attributed text, flowing across pages as needed.
        mutating func draw(text: NSAttributedString, badge: Int? = nil) {
            let framesetter = CTFramesetterCreateWithAttributedString(text)
            var location = 0
            let length = text.length
            let badgeInset: CGFloat = badge == nil ? 0 : 20

            while location < length {
                if remaining < 30 { beginPage() }

                let available = CGSize(width: contentWidth - badgeInset, height: remaining)
                var fitRange = CFRange()
                let size = CTFramesetterSuggestFrameSizeWithConstraints(
                    framesetter,
                    CFRange(location: location, length: length - location),
                    nil,
                    available,
                    &fitRange
                )
                if fitRange.length == 0 {
                    beginPage()
                    continue
                }

                let frameRect = CGRect(
                    x: margin + badgeInset,
                    y: pageSize.height - cursorY - size.height,
                    width: available.width,
                    height: size.height
                )
                let path = CGPath(rect: frameRect, transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: fitRange.length), path, nil)

                context.saveGState()
                context.textMatrix = .identity
                CTFrameDraw(frame, context)
                context.restoreGState()

                if let badge, location == 0 {
                    drawBadge(number: badge, topY: cursorY, lineHeight: min(size.height, 16))
                }

                cursorY += size.height
                location += fitRange.length
            }
        }

        private func drawBadge(number: Int, topY: CGFloat, lineHeight: CGFloat) {
            let diameter: CGFloat = 14
            let centerY = pageSize.height - topY - lineHeight / 2
            let rect = CGRect(x: margin, y: centerY - diameter / 2, width: diameter, height: diameter)
            context.saveGState()
            context.setFillColor(CGColor(red: 0.92, green: 0.2, blue: 0.2, alpha: 1))
            context.fillEllipse(in: rect)

            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 8.5),
                .foregroundColor: NSColor.white
            ])
            let line = CTLineCreateWithAttributedString(label)
            let bounds = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])
            context.textMatrix = .identity
            context.textPosition = CGPoint(
                x: rect.midX - bounds.width / 2,
                y: rect.midY - bounds.height / 2 + 1
            )
            CTLineDraw(line, context)
            context.restoreGState()
        }

        /// Draws an image scaled to fit the content width / maxHeight, moving to
        /// a new page first if it does not fit the remaining space.
        mutating func draw(image: CGImage, maxHeight: CGFloat, maxWidth: CGFloat? = nil) {
            let widthLimit = min(maxWidth ?? contentWidth, contentWidth)
            let imageSize = CGSize(width: image.width, height: image.height)
            guard imageSize.width > 0, imageSize.height > 0 else { return }

            let scale = min(widthLimit / imageSize.width, maxHeight / imageSize.height, 1)
            let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)

            if drawSize.height > remaining {
                beginPage()
            }

            let rect = CGRect(
                x: margin,
                y: pageSize.height - cursorY - drawSize.height,
                width: drawSize.width,
                height: drawSize.height
            )
            context.saveGState()
            context.interpolationQuality = .high
            context.draw(image, in: rect)
            // Thin border so white screenshots stand out on the page
            context.setStrokeColor(CGColor(gray: 0.8, alpha: 1))
            context.setLineWidth(0.5)
            context.stroke(rect)
            context.restoreGState()

            cursorY += drawSize.height
        }
    }
}
