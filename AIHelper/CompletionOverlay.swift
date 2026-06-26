import SwiftUI
import AppKit
import os.log

// Extension to tint NSImage with a color
private extension NSImage {
    func image(with tintColor: NSColor) -> NSImage {
        if self.isTemplate {
            let image = self.copy() as! NSImage
            image.lockFocus()
            tintColor.set()
            let imageRect = NSRect(origin: .zero, size: image.size)
            imageRect.fill(using: .sourceIn)
            image.unlockFocus()
            image.isTemplate = false
            return image
        } else {
            return self
        }
    }
}

private let logger = Logger(subsystem: "com.aihelper.app", category: "StatusOverlay")

enum OverlayState {
    case recording
    case recordingEmail
    case recordingCasualMessage
    case transcribing
    case formatting
    case completed
}

@MainActor
class StatusOverlay {
    static let shared = StatusOverlay()

    /// Main status window (recording, transcribing, formatting, completed)
    private var statusWindow: NSWindow?
    private var currentState: OverlayState?
    private var timeLayer: CATextLayer?
    private var displayTimer: Timer?

    /// Separate toast window for brief messages - doesn't interfere with status window
    private var toastWindow: NSWindow?

    private init() {
        logger.info("StatusOverlay initialized")
    }

    func show(state: OverlayState) {
        logger.info("show(state:) called with state: \(String(describing: state))")

        // Always close existing status window first
        if let existingWindow = statusWindow {
            existingWindow.contentView = nil
            existingWindow.orderOut(nil)
            statusWindow = nil
        }
        stopDisplayTimer()
        timeLayer = nil

        currentState = state

        // Get mouse location
        let mouseLocation = NSEvent.mouseLocation
        logger.debug("Mouse location: \(mouseLocation.x), \(mouseLocation.y)")

        // Use wider window for recording states to show timer
        let isRecordingState = state == .recording || state == .recordingEmail || state == .recordingCasualMessage
        let windowWidth: CGFloat = isRecordingState ? 110 : 50

        // Create the overlay window
        let overlayWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: 50),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        overlayWindow.isOpaque = false
        overlayWindow.backgroundColor = .clear
        overlayWindow.level = .floating
        overlayWindow.hasShadow = true
        overlayWindow.ignoresMouseEvents = true
        overlayWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Position near mouse
        let windowFrame = NSRect(
            x: mouseLocation.x + 20,
            y: mouseLocation.y - 25,
            width: windowWidth,
            height: 50
        )
        overlayWindow.setFrame(windowFrame, display: true)

        // Create content view based on state - use NSView instead of SwiftUI
        let contentView = createContentView(for: state)
        overlayWindow.contentView = contentView

        // Show window
        overlayWindow.orderFront(nil)
        self.statusWindow = overlayWindow
        logger.info("Status window created and shown")

        // Start timer to update recording duration display
        if isRecordingState {
            startDisplayTimer()
        }

        // For completed state, auto-dismiss after delay
        if state == .completed {
            logger.debug("Scheduling auto-dismiss for completed state")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.hide()
            }
        }
    }

    func hide() {
        logger.info("hide() called")
        stopDisplayTimer()
        timeLayer = nil
        if let existingWindow = statusWindow {
            existingWindow.contentView = nil
            existingWindow.orderOut(nil)
        }
        statusWindow = nil
        currentState = nil
    }

    func showBrief(message: String) {
        logger.info("showBrief() called with message: \(message)")

        // Close any existing toast window (but leave statusWindow alone!)
        if let existingToast = toastWindow {
            existingToast.contentView = nil
            existingToast.orderOut(nil)
            toastWindow = nil
        }

        // Get mouse location
        let mouseLocation = NSEvent.mouseLocation

        // Calculate width based on message length
        let estimatedWidth = max(150, min(300, CGFloat(message.count * 10) + 40))

        // Create a separate toast window
        let toast = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: estimatedWidth, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        toast.isOpaque = false
        toast.backgroundColor = .clear
        toast.level = .floating
        toast.hasShadow = true
        toast.ignoresMouseEvents = true
        toast.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Position below the status window (if visible) or near mouse
        let yOffset: CGFloat = statusWindow != nil ? -70 : -20
        let windowFrame = NSRect(
            x: mouseLocation.x + 20,
            y: mouseLocation.y + yOffset,
            width: estimatedWidth,
            height: 40
        )
        toast.setFrame(windowFrame, display: true)

        // Create content view with message
        let contentView = createMessageView(message: message, width: estimatedWidth)
        toast.contentView = contentView

        // Show toast window
        toast.orderFront(nil)
        self.toastWindow = toast
        logger.info("Toast window created and shown (status window unchanged)")

        // Auto-dismiss toast after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            if let existingToast = self.toastWindow {
                existingToast.contentView = nil
                existingToast.orderOut(nil)
                self.toastWindow = nil
            }
        }
    }

    private func createMessageView(message: String, width: CGFloat) -> NSView {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 40))
        containerView.wantsLayer = true

        // Create rounded rect background
        let backgroundLayer = CAShapeLayer()
        let roundedRect = CGPath(roundedRect: CGRect(x: 2, y: 2, width: width - 4, height: 36),
                                  cornerWidth: 8, cornerHeight: 8, transform: nil)
        backgroundLayer.path = roundedRect
        backgroundLayer.fillColor = NSColor.systemGreen.cgColor
        backgroundLayer.shadowColor = NSColor.black.cgColor
        backgroundLayer.shadowOffset = CGSize(width: 0, height: -2)
        backgroundLayer.shadowOpacity = 0.3
        backgroundLayer.shadowRadius = 4

        containerView.layer?.addSublayer(backgroundLayer)

        // Create text layer
        let textLayer = CATextLayer()
        textLayer.frame = CGRect(x: 10, y: 8, width: width - 20, height: 24)
        textLayer.alignmentMode = .center
        textLayer.fontSize = 14
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.string = message
        textLayer.truncationMode = .end
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0

        containerView.layer?.addSublayer(textLayer)

        return containerView
    }

    private func createContentView(for state: OverlayState) -> NSView {
        let isRecordingState = state == .recording || state == .recordingEmail || state == .recordingCasualMessage
        let viewWidth: CGFloat = isRecordingState ? 110 : 50

        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: viewWidth, height: 50))
        containerView.wantsLayer = true

        // Create circle layer
        let circleLayer = CAShapeLayer()
        let circlePath = CGPath(ellipseIn: CGRect(x: 5, y: 5, width: 40, height: 40), transform: nil)
        circleLayer.path = circlePath
        circleLayer.fillColor = colorForState(state).cgColor
        circleLayer.shadowColor = NSColor.black.cgColor
        circleLayer.shadowOffset = CGSize(width: 0, height: -2)
        circleLayer.shadowOpacity = 0.3
        circleLayer.shadowRadius = 4

        containerView.layer?.addSublayer(circleLayer)

        // Create icon layer using SF Symbol
        let iconLayer = CALayer()
        iconLayer.frame = CGRect(x: 13, y: 13, width: 24, height: 24)
        if let symbolImage = NSImage(systemSymbolName: sfSymbolForState(state), accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
            let configuredImage = symbolImage.withSymbolConfiguration(config)
            let tintedImage = configuredImage?.image(with: .white)
            iconLayer.contents = tintedImage
            iconLayer.contentsGravity = .resizeAspect
        }
        iconLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0

        containerView.layer?.addSublayer(iconLayer)

        // Add time display for recording states
        if isRecordingState {
            let timeLabelLayer = CATextLayer()
            timeLabelLayer.frame = CGRect(x: 50, y: 14, width: 55, height: 24)
            timeLabelLayer.alignmentMode = .left
            timeLabelLayer.fontSize = 16
            timeLabelLayer.foregroundColor = colorForState(state).cgColor
            timeLabelLayer.string = "0:00"
            timeLabelLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            timeLabelLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .medium)

            containerView.layer?.addSublayer(timeLabelLayer)
            self.timeLayer = timeLabelLayer
        }

        // Add animations based on state (respecting Reduce Motion preference)
        let shouldAnimate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldAnimate {
            if isRecordingState {
                addPulseAnimation(to: circleLayer)
            } else if state == .transcribing || state == .formatting {
                addSpinAnimation(to: iconLayer, in: containerView)
            }
        }

        return containerView
    }

    private func colorForState(_ state: OverlayState) -> NSColor {
        switch state {
        case .recording: return NSColor.systemRed
        case .recordingEmail: return NSColor.systemOrange
        case .recordingCasualMessage: return NSColor.systemGreen
        case .transcribing: return NSColor.systemBlue
        case .formatting: return NSColor.systemPurple
        case .completed: return NSColor.systemGreen
        }
    }

    private func sfSymbolForState(_ state: OverlayState) -> String {
        switch state {
        case .recording: return "record.circle.fill"
        case .recordingEmail: return "envelope.fill"
        case .recordingCasualMessage: return "message.fill"
        case .transcribing: return "waveform"
        case .formatting: return "text.alignleft"
        case .completed: return "checkmark"
        }
    }

    private func addPulseAnimation(to layer: CAShapeLayer) {
        let pulseAnimation = CABasicAnimation(keyPath: "opacity")
        pulseAnimation.fromValue = 1.0
        pulseAnimation.toValue = 0.6
        pulseAnimation.duration = 0.8
        pulseAnimation.autoreverses = true
        pulseAnimation.repeatCount = .infinity
        layer.add(pulseAnimation, forKey: "pulse")
    }

    private func addSpinAnimation(to layer: CALayer, in view: NSView) {
        // Use a simpler approach - just animate opacity for "loading" effect
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.4
        animation.duration = 0.5
        animation.autoreverses = true
        animation.repeatCount = .infinity
        layer.add(animation, forKey: "loading")
    }

    private func startDisplayTimer() {
        stopDisplayTimer()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateTimeDisplay()
            }
        }
        // Update immediately
        updateTimeDisplay()
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func updateTimeDisplay() {
        guard let timeLayer = timeLayer else { return }

        let recordingTime = AppState.shared.recordingManager.audioRecorder.recordingTime
        let minutes = Int(recordingTime) / 60
        let seconds = Int(recordingTime) % 60
        timeLayer.string = String(format: "%d:%02d", minutes, seconds)
    }
}

// Keep the old API for backward compatibility
class CompletionOverlay {
    static let shared = CompletionOverlay()
    private init() {}

    @MainActor
    func show() {
        StatusOverlay.shared.show(state: .completed)
    }
}
