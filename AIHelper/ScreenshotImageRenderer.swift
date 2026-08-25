import AppKit
import CoreGraphics

/// Draws numbered markers onto a screenshot and cuts out marked regions.
/// All work happens in pixel space so Retina captures stay crisp.
enum ScreenshotImageRenderer {

    enum Format {
        case png
        case jpeg(quality: CGFloat)

        var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            }
        }

        /// Format used for a file with the given name (old sessions are PNG).
        static func forFileName(_ name: String) -> Format {
            let ext = (name as NSString).pathExtension.lowercased()
            return ext == "png" ? .png : .stored
        }

        /// What new captures are written as.
        static let stored = Format.jpeg(quality: 0.82)
    }

    /// Longest side for stored screenshots – keeps text legible, shrinks Retina captures.
    static let storedMaxDimension: CGFloat = 3000

    /// Decodes PNG or JPEG data (name kept for call-site compatibility).
    static func cgImage(fromPNG data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func pngData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        // Flatten onto white: JPEG has no alpha
        let rep = NSBitmapImageRep(cgImage: flattened(image))
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    static func data(from image: CGImage, format: Format) -> Data? {
        switch format {
        case .png: return pngData(from: image)
        case .jpeg(let q): return jpegData(from: image, quality: q)
        }
    }

    /// Scales the image down so its longest side is at most `maxDimension`.
    static func downscaled(_ image: CGImage, maxDimension: CGFloat) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let longest = max(w, h)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        guard let ctx = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage() ?? image
    }

    private static func flattened(_ image: CGImage) -> CGImage {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst else { return image }
        guard let ctx = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    /// Returns an encoded image with red rectangles and numbered badges for each region.
    static func annotatedImage(original: CGImage, regions: [ScreenshotRegion], format: Format) -> Data? {
        guard let image = annotatedCGImage(original: original, regions: regions) else { return nil }
        return data(from: image, format: format)
    }

    /// Compatibility wrapper (PNG).
    static func annotatedPNG(original: CGImage, regions: [ScreenshotRegion]) -> Data? {
        annotatedImage(original: original, regions: regions, format: .png)
    }

    static func annotatedCGImage(original: CGImage, regions: [ScreenshotRegion]) -> CGImage? {
        let width = original.width
        let height = original.height
        let pixelSize = CGSize(width: width, height: height)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Draw original
        context.draw(original, in: CGRect(origin: .zero, size: pixelSize))

        // Flip so we can work with top-left origin like the regions
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        // Scale line widths and badges with the image so they stay readable
        let scale = max(1, CGFloat(min(width, height)) / 900)
        let lineWidth = 3 * scale
        let badgeSize = 26 * scale
        let accent = NSColor(calibratedRed: 0.92, green: 0.2, blue: 0.2, alpha: 1)

        for (offset, region) in regions.enumerated() {
            let rect = region.pixelRect(in: pixelSize)

            // Rectangle
            let path = NSBezierPath(rect: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
            path.lineWidth = lineWidth
            accent.setStroke()
            path.stroke()

            // Thin white halo for contrast on dark/red backgrounds
            let halo = NSBezierPath(rect: rect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2))
            halo.lineWidth = max(1, scale)
            NSColor.white.withAlphaComponent(0.8).setStroke()
            halo.stroke()

            // Badge at top-left corner (slightly outside when possible)
            var badgeOrigin = CGPoint(x: rect.minX - badgeSize * 0.35, y: rect.minY - badgeSize * 0.35)
            badgeOrigin.x = max(0, min(badgeOrigin.x, CGFloat(width) - badgeSize))
            badgeOrigin.y = max(0, min(badgeOrigin.y, CGFloat(height) - badgeSize))
            let badgeRect = CGRect(origin: badgeOrigin, size: CGSize(width: badgeSize, height: badgeSize))

            let circle = NSBezierPath(ovalIn: badgeRect)
            accent.setFill()
            circle.fill()
            NSColor.white.setStroke()
            circle.lineWidth = max(1, 1.5 * scale)
            circle.stroke()

            let number = "\(offset + 1)" as NSString
            let font = NSFont.boldSystemFont(ofSize: badgeSize * 0.58)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white
            ]
            let textSize = number.size(withAttributes: attributes)
            let textOrigin = CGPoint(
                x: badgeRect.midX - textSize.width / 2,
                y: badgeRect.midY - textSize.height / 2
            )
            number.draw(at: textOrigin, withAttributes: attributes)
        }

        NSGraphicsContext.restoreGraphicsState()

        return context.makeImage()
    }

    /// Crops a region out of the original image (pixel space, top-left origin).
    static func cropCGImage(original: CGImage, region: ScreenshotRegion) -> CGImage? {
        let pixelSize = CGSize(width: original.width, height: original.height)
        var rect = region.pixelRect(in: pixelSize)
        rect = rect.intersection(CGRect(origin: .zero, size: pixelSize))
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        // CGImage.cropping uses top-left origin, matching our regions
        return original.cropping(to: rect)
    }

    static func cropImage(original: CGImage, region: ScreenshotRegion, format: Format) -> Data? {
        guard let cropped = cropCGImage(original: original, region: region) else { return nil }
        return data(from: cropped, format: format)
    }

    /// Compatibility wrapper (PNG).
    static func cropPNG(original: CGImage, region: ScreenshotRegion) -> Data? {
        cropImage(original: original, region: region, format: .png)
    }

    /// Small preview used in the session strip.
    static func thumbnail(from image: NSImage, maxDimension: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(maxDimension / size.width, maxDimension / size.height, 1)
        let target = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target))
        thumb.unlockFocus()
        return thumb
    }
}
