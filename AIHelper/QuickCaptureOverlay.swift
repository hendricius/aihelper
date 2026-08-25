import AppKit

/// Full-screen, transparent overlay that shows the frozen screenshot in place
/// and lets the user drag a rectangle on it. Coordinates are handed back
/// normalized to the screenshot (0...1, origin top-left).
final class QuickCaptureOverlayWindow: NSWindow {
    private let overlayView: QuickCaptureOverlayView

    /// - Parameters:
    ///   - screen: screen to cover
    ///   - image: frozen screenshot
    ///   - imageFrame: where the screenshot sits on that screen (Cocoa screen coordinates)
    ///   - onRegion: called with a normalized rect, or nil for "whole page" (↩)
    ///   - onCancel: called on Esc
    init(
        screen: NSScreen,
        image: NSImage,
        imageFrame: NSRect,
        onRegion: @escaping (CGRect?, NSRect?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let frame = screen.frame
        // Convert to window-local, flipped (top-left origin) coordinates
        let localImageFrame = NSRect(
            x: imageFrame.minX - frame.minX,
            y: frame.maxY - imageFrame.maxY,
            width: imageFrame.width,
            height: imageFrame.height
        )
        overlayView = QuickCaptureOverlayView(
            frame: NSRect(origin: .zero, size: frame.size),
            image: image,
            imageFrame: localImageFrame
        )

        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true

        overlayView.onRegion = { normalized, localRect in
            // Convert the local (flipped) rect back to Cocoa screen coordinates for HUD placement
            let screenRect = localRect.map { r in
                NSRect(
                    x: frame.minX + r.minX,
                    y: frame.maxY - r.maxY,
                    width: r.width,
                    height: r.height
                )
            }
            onRegion(normalized, screenRect)
        }
        overlayView.onCancel = onCancel
        contentView = overlayView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func present() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        makeFirstResponder(overlayView)
        NSCursor.crosshair.set()
    }
}

final class QuickCaptureOverlayView: NSView {
    var onRegion: ((CGRect?, NSRect?) -> Void)?
    var onCancel: (() -> Void)?

    private let image: NSImage
    private let imageFrame: NSRect
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private let minimumSide: CGFloat = 6

    init(frame: NSRect, image: NSImage, imageFrame: NSRect) {
        self.image = image
        self.imageFrame = imageFrame
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Dim everything that is not the captured window
        NSColor.black.withAlphaComponent(0.55).setFill()
        bounds.fill()

        // Frozen screenshot in place
        image.draw(in: imageFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])

        // Light veil over the screenshot with a hole for the selection
        let veil = NSBezierPath(rect: imageFrame)
        if let sel = selectionRect {
            veil.append(NSBezierPath(rect: sel).reversed)
        }
        NSColor.black.withAlphaComponent(0.22).setFill()
        veil.windingRule = .evenOdd
        veil.fill()

        // Window outline
        NSColor.white.withAlphaComponent(0.6).setStroke()
        let outline = NSBezierPath(rect: imageFrame.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 1
        outline.stroke()

        if let sel = selectionRect {
            let path = NSBezierPath(rect: sel)
            path.lineWidth = 2
            NSColor(calibratedRed: 0.92, green: 0.2, blue: 0.2, alpha: 1).setStroke()
            path.stroke()

            let label = "\(Int(sel.width)) × \(Int(sel.height))"
            drawPill(text: label, at: NSPoint(x: sel.minX, y: sel.maxY + 6), font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium))
        }

        // Instructions (two stacked pills above the captured window)
        let hintFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let subFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let hint = "Drag to mark an area   ·   ↩ note for the whole page   ·   esc cancel"
        let sub = "After saving:  \(ShortcutConfig.annotateScreenshot.displayString) next screenshot   ·   \(ShortcutConfig.finishScreenshotSession.displayString) export for your agent   ·   \(ShortcutConfig.reviewScreenshotSession.displayString) review"
        let hintSize = pillSize(text: hint, font: hintFont)
        let subSize = pillSize(text: sub, font: subFont)
        let top = max(12, imageFrame.minY - hintSize.height - subSize.height - 18)
        drawPill(text: hint, at: NSPoint(x: bounds.midX - hintSize.width / 2, y: top), font: hintFont)
        drawPill(text: sub, at: NSPoint(x: bounds.midX - subSize.width / 2, y: top + hintSize.height + 6), font: subFont)
    }

    private func pillSize(text: String, font: NSFont) -> NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (text as NSString).size(withAttributes: attrs)
        return NSSize(width: textSize.width + 20, height: textSize.height + 10)
    }

    private func drawPill(text: String, at origin: NSPoint, font: NSFont) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let textSize = (text as NSString).size(withAttributes: attrs)
        var rect = NSRect(x: origin.x, y: origin.y, width: textSize.width + 20, height: textSize.height + 10)
        rect.origin.x = min(max(rect.origin.x, 8), bounds.maxX - rect.width - 8)
        rect.origin.y = min(max(rect.origin.y, 8), bounds.maxY - rect.height - 8)
        let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.black.withAlphaComponent(0.75).setFill()
        pill.fill()
        (text as NSString).draw(at: NSPoint(x: rect.minX + 10, y: rect.minY + 5), withAttributes: attrs)
    }

    private var selectionRect: NSRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        let rect = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        return rect.intersection(imageFrame)
    }

    // MARK: Mouse / keyboard

    private func clamp(_ point: NSPoint) -> NSPoint {
        NSPoint(
            x: min(max(point.x, imageFrame.minX), imageFrame.maxX),
            y: min(max(point.y, imageFrame.minY), imageFrame.maxY)
        )
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = clamp(convert(event.locationInWindow, from: nil))
        dragCurrent = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = clamp(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            dragCurrent = nil
            needsDisplay = true
        }
        guard let sel = selectionRect, sel.width >= minimumSide, sel.height >= minimumSide else { return }
        let normalized = CGRect(
            x: (sel.minX - imageFrame.minX) / imageFrame.width,
            y: (sel.minY - imageFrame.minY) / imageFrame.height,
            width: sel.width / imageFrame.width,
            height: sel.height / imageFrame.height
        )
        onRegion?(normalized, sel)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // esc
            onCancel?()
        case 36, 76: // return / enter
            onRegion?(nil, nil)
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
