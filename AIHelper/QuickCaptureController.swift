import AppKit
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "QuickCapture")

/// Orchestrates the quick flow: freeze screenshot → crosshair overlay →
/// small note HUD → save. Designed to keep the user in the browser.
@MainActor
final class QuickCaptureController {
    static let shared = QuickCaptureController()

    private struct Context {
        var capture: ScreenshotCapture
        let image: NSImage
        let cgImage: CGImage?
        let screen: NSScreen
        /// Where the frozen screenshot sits, Cocoa screen coordinates
        let imageFrame: NSRect
    }

    private var context: Context?
    private var overlay: QuickCaptureOverlayWindow?
    private let hud = QuickNoteHUDController()
    private var hudModel: QuickNoteModel?
    private var isCapturing = false

    private var store: ScreenshotNotesStore { ScreenshotNotesStore.shared }

    // MARK: - Entry

    func start() {
        ScreenshotNotesLog.log("Quick capture hotkey (capturing=\(isCapturing), overlay=\(overlay != nil), hud=\(hudModel != nil))")
        guard !isCapturing else { return }
        if overlay != nil {
            // Hotkey pressed while the overlay is up: treat as cancel
            cancelOverlay()
            return
        }
        if hudModel != nil {
            // Hotkey while a note is open: save it, then take a fresh capture
            hudModel?.finish(.done)
        }

        isCapturing = true
        Task { @MainActor in
            defer { isCapturing = false }

            // Never capture our own editor window
            ScreenshotAnnotationWindowController.shared.hideForCapture()
            try? await Task.sleep(for: .milliseconds(120))

            do {
                let result = try await ScreenCaptureService.shared.captureFrontmostWindow()
                ScreenshotNotesLog.log("Captured \(Int(result.pixelSize.width))x\(Int(result.pixelSize.height)) px, app=\(result.info.appName ?? "-"), title=\(result.info.windowTitle ?? "-"), url=\(result.info.pageURL ?? "-"), bounds=\(result.windowBounds.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "full screen")")
                let capture = try store.addCapture(result)
                guard let image = store.image(for: capture) else {
                    throw ScreenCaptureError.invalidImage
                }
                let placement = Self.placement(for: result.windowBounds)
                ScreenshotNotesLog.log("Placement: screen=\(placement.screen.localizedName) frame=\(placement.screen.frame), image frame=\(placement.frame)")
                context = Context(
                    capture: capture,
                    image: image,
                    cgImage: store.cgImage(for: capture),
                    screen: placement.screen,
                    imageFrame: placement.frame
                )
                showOverlay()
            } catch ScreenCaptureError.permissionDenied {
                ScreenshotNotesLog.error("Screen recording permission missing")
                StatusOverlay.shared.showBrief(message: "Allow Screen Recording for AIHelper, then try again")
            } catch {
                ScreenshotNotesLog.error("Quick capture failed: \(error)")
                logger.error("Quick capture failed: \(error.localizedDescription)")
                StatusOverlay.shared.showBrief(message: error.localizedDescription)
            }
        }
    }

    /// Saves a note popup that is still open. A running recording is stopped
    /// and finishes transcribing in the background – the text is appended to
    /// the note when it arrives. Used by ⌃⌥⌘⇧D so nothing gets lost.
    func finishPendingNote() {
        guard let hudModel else { return }
        ScreenshotNotesLog.log("Finishing pending HUD note before review/export")
        hudModel.finish(.done)
    }

    // MARK: - Background transcription

    /// Notes whose dictation was still transcribing when their popup was saved.
    private(set) var pendingTranscriptions = 0

    /// Lets exports wait until late transcripts have landed in their notes.
    func waitForPendingTranscriptions(timeout: TimeInterval = 15) async {
        guard pendingTranscriptions > 0 else { return }
        ScreenshotNotesLog.log("Waiting for \(pendingTranscriptions) background transcription(s)")
        let deadline = Date().addingTimeInterval(timeout)
        while pendingTranscriptions > 0, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if pendingTranscriptions > 0 {
            ScreenshotNotesLog.error("Continuing without \(pendingTranscriptions) pending transcription(s) (timeout)")
        }
    }

    /// A transcript that finished after its popup was saved: append it to the
    /// note it belongs to – in the current session, or in the session it moved
    /// to (exported/parked) in the meantime.
    private func backgroundTranscriptArrived(_ transcript: String, captureID: UUID, regionID: UUID?) {
        pendingTranscriptions = max(0, pendingTranscriptions - 1)
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            ScreenshotNotesLog.log("Background transcription empty or failed for capture \(captureID)")
            return
        }

        if var capture = store.capture(withID: captureID) {
            if let regionID {
                guard let idx = capture.regions.firstIndex(where: { $0.id == regionID }) else { return }
                capture.regions[idx].note = Self.joined(capture.regions[idx].note, trimmed)
            } else {
                capture.generalNote = Self.joined(capture.generalNote, trimmed)
            }
            store.update(capture)
            if context?.capture.id == captureID, let fresh = store.capture(withID: captureID) {
                context?.capture = fresh
            }
            ScreenshotAnnotationWindowController.shared.reloadIfShowing(captureID: captureID)
            ScreenshotNotesLog.log("Background transcript (\(trimmed.count) chars) added to capture #\(capture.index) (\(regionID == nil ? "page" : "area"))")
            StatusOverlay.shared.showBrief(message: "Dictation added to screenshot \(capture.index)")
            return
        }

        if appendToArchivedSession(trimmed, captureID: captureID, regionID: regionID) { return }
        ScreenshotNotesLog.error("Background transcript dropped – capture \(captureID) no longer exists")
    }

    /// The session was exported or parked before the transcript arrived: patch
    /// its session.json/notes.md on disk. PDF/ZIP refresh on the next copy.
    private func appendToArchivedSession(_ transcript: String, captureID: UUID, regionID: UUID?) -> Bool {
        for entry in ScreenshotHistoryStore.shared.entries {
            guard var session = ScreenshotSessionExporter.loadSession(in: entry.folder),
                  let ci = session.captures.firstIndex(where: { $0.id == captureID }) else { continue }
            if let regionID {
                guard let ri = session.captures[ci].regions.firstIndex(where: { $0.id == regionID }) else { return false }
                session.captures[ci].regions[ri].note = Self.joined(session.captures[ci].regions[ri].note, transcript)
            } else {
                session.captures[ci].generalNote = Self.joined(session.captures[ci].generalNote, transcript)
            }
            do {
                try ScreenshotSessionExporter.saveSession(session, in: entry.folder)
                try ScreenshotSessionExporter.writeNotes(for: session, folder: entry.folder)
            } catch {
                ScreenshotNotesLog.error("Could not save late transcript to \(entry.folder.lastPathComponent): \(error.localizedDescription)")
                return false
            }
            ScreenshotHistoryStore.shared.refresh()
            ScreenshotNotesLog.log("Background transcript added to session \(entry.folder.lastPathComponent) in History")
            StatusOverlay.shared.showBrief(message: "Dictation added to exported session – copy its PDF again from History")
            return true
        }
        return false
    }

    private static func joined(_ existing: String, _ addition: String) -> String {
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? addition : trimmed + " " + addition
    }

    // MARK: - Placement

    /// Converts Quartz window bounds (origin top-left of main display) into the
    /// screen that contains them and a Cocoa rect on that screen.
    private static func placement(for bounds: CGRect?) -> (screen: NSScreen, frame: NSRect) {
        let screens = NSScreen.screens
        let primary = screens.first ?? NSScreen.main!
        guard let bounds else {
            let screen = NSScreen.main ?? primary
            return (screen, screen.frame)
        }
        let cocoa = NSRect(
            x: bounds.minX,
            y: primary.frame.maxY - bounds.maxY,
            width: bounds.width,
            height: bounds.height
        )
        let center = NSPoint(x: cocoa.midX, y: cocoa.midY)
        let screen = screens.first { $0.frame.contains(center) }
            ?? screens.max { $0.frame.intersection(cocoa).area < $1.frame.intersection(cocoa).area }
            ?? primary
        return (screen, cocoa.intersection(screen.frame))
    }

    // MARK: - Overlay

    private func showOverlay() {
        guard let ctx = context else { return }
        hud.dismiss()
        hudModel = nil

        let window = QuickCaptureOverlayWindow(
            screen: ctx.screen,
            image: ctx.image,
            imageFrame: ctx.imageFrame,
            onRegion: { [weak self] normalized, screenRect in
                self?.overlayDidSelect(normalized: normalized, screenRect: screenRect)
            },
            onCancel: { [weak self] in
                self?.cancelOverlay()
            }
        )
        overlay = window
        window.present()
        ScreenshotNotesLog.log("Overlay presented")
    }

    private func closeOverlay() {
        overlay?.orderOut(nil)
        overlay = nil
        NSCursor.arrow.set()
    }

    private func cancelOverlay() {
        ScreenshotNotesLog.log("Overlay cancelled")
        closeOverlay()
        guard let ctx = context else { return }
        if ctx.capture.regions.isEmpty, ctx.capture.generalNote.isEmpty {
            // Nothing was kept – drop the screenshot again
            store.delete(ctx.capture)
            StatusOverlay.shared.showBrief(message: "Capture discarded")
        } else {
            store.update(ctx.capture)
        }
        context = nil
    }

    private func overlayDidSelect(normalized: CGRect?, screenRect: NSRect?) {
        ScreenshotNotesLog.log("Overlay selection: normalized=\(normalized.map { String(format: "%.3f,%.3f %.3fx%.3f", $0.minX, $0.minY, $0.width, $0.height) } ?? "whole page"), screen rect=\(screenRect.map { "\($0)" } ?? "-")")
        guard var ctx = context else { return }
        closeOverlay()

        var areaNumber: Int?
        var thumbnail: NSImage?
        var regionID: UUID?

        if let normalized {
            let region = ScreenshotRegion(rect: normalized)
            ctx.capture.regions.append(region)
            regionID = region.id
            areaNumber = ctx.capture.regions.count
            if let cg = ctx.cgImage,
               let cropCG = ScreenshotImageRenderer.cropCGImage(original: cg, region: region) {
                thumbnail = NSImage(cgImage: cropCG, size: NSSize(width: cropCG.width, height: cropCG.height))
            }
        }
        context = ctx

        let captureID = ctx.capture.id
        let model = QuickNoteModel(areaNumber: areaNumber, pageTitle: ctx.capture.displayTitle, thumbnail: thumbnail)
        model.onFinish = { [weak self, weak model] action, text in
            self?.hudDidFinish(
                action: action,
                text: text,
                captureID: captureID,
                regionID: regionID,
                pendingTranscription: model?.scheduledBackgroundTranscription ?? false
            )
        }
        model.onBackgroundTranscript = { [weak self] transcript in
            self?.backgroundTranscriptArrived(transcript, captureID: captureID, regionID: regionID)
        }
        model.onCancel = { [weak self] in
            self?.hudDidCancel(captureID: captureID, regionID: regionID)
        }
        hudModel = model
        hud.show(model: model, near: screenRect, on: ctx.screen)
    }

    // MARK: - HUD results

    /// The capture a HUD belongs to: the live context if it is still the same
    /// capture, otherwise (hotkey pressed meanwhile) the stored copy.
    private func workingCapture(for captureID: UUID) -> (capture: ScreenshotCapture, isCurrent: Bool)? {
        if let ctx = context, ctx.capture.id == captureID {
            return (ctx.capture, true)
        }
        if let stored = store.capture(withID: captureID) {
            return (stored, false)
        }
        return nil
    }

    private func hudDidFinish(action: QuickNoteModel.Action, text: String, captureID: UUID, regionID: UUID?, pendingTranscription: Bool = false) {
        if pendingTranscription { pendingTranscriptions += 1 }
        if hudModel != nil, context?.capture.id == captureID || context == nil {
            hud.dismiss()
            hudModel = nil
        }
        guard let working = workingCapture(for: captureID) else { return }
        var capture = working.capture
        let isCurrent = working.isCurrent

        if let regionID, let idx = capture.regions.firstIndex(where: { $0.id == regionID }) {
            capture.regions[idx].note = text
        } else if regionID == nil {
            capture.generalNote = text
        }
        store.update(capture)
        if isCurrent { context?.capture = capture }
        ScreenshotNotesLog.log("Saved note for capture #\(capture.index) (\(regionID == nil ? "page" : "area"), \(text.count) chars), action=\(action)")
        ScreenshotAnnotationWindowController.shared.reloadIfShowing(captureID: capture.id)

        let what = regionID == nil ? "Page note" : "Area \(capture.regions.count)"
        let count = store.session.captures.count

        switch action {
        case .done:
            let saved = pendingTranscription ? "\(what) saved – dictation lands in a moment" : "\(what) saved"
            StatusOverlay.shared.showBrief(message: "\(saved) (\(count) in session) · \(ShortcutConfig.annotateScreenshot.displayString) next · \(ShortcutConfig.finishScreenshotSession.displayString) export")
            if isCurrent { context = nil }
        case .addArea:
            if isCurrent {
                showOverlay()
            } else {
                StatusOverlay.shared.showBrief(message: "\(what) saved")
            }
        case .openEditor:
            if isCurrent { context = nil }
            ScreenshotAnnotationWindowController.shared.open(capture: capture, isNew: false)
        }
    }

    private func hudDidCancel(captureID: UUID, regionID: UUID?) {
        if context?.capture.id == captureID || context == nil {
            hud.dismiss()
            hudModel = nil
        }
        guard let working = workingCapture(for: captureID) else { return }
        var capture = working.capture
        let isCurrent = working.isCurrent

        if let regionID {
            capture.regions.removeAll { $0.id == regionID }
        }

        if capture.regions.isEmpty, capture.generalNote.isEmpty {
            store.delete(capture)
            StatusOverlay.shared.showBrief(message: "Capture discarded")
        } else {
            store.update(capture)
            StatusOverlay.shared.showBrief(message: "Area discarded")
        }
        if isCurrent { context = nil }
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
