import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "ScreenshotAnnotationWindow")

/// Single annotation window. Capturing a new screenshot while it is open
/// commits the current capture and switches the window to the new one.
@MainActor
final class ScreenshotAnnotationWindowController: NSObject, NSWindowDelegate {
    static let shared = ScreenshotAnnotationWindowController()

    private var window: NSWindow?
    private var model: ScreenshotAnnotationModel?
    private var isCapturing = false

    private var store: ScreenshotNotesStore { ScreenshotNotesStore.shared }

    // MARK: - Capture flow

    /// Hotkey entry point. Quick mode hands off to the crosshair/HUD flow,
    /// editor mode captures and opens the full window.
    func captureAndAnnotate() {
        if ScreenshotNotesStore.CaptureMode.current == .quick {
            QuickCaptureController.shared.start()
            return
        }
        captureIntoEditor()
    }

    /// Hides the editor so it never ends up in a screenshot.
    func hideForCapture() {
        if window?.isVisible == true {
            commitCurrentModel()
            window?.orderOut(nil)
        }
    }

    /// Capture the frontmost window and open it for annotation in the editor.
    func captureIntoEditor() {
        guard !isCapturing else {
            logger.debug("Capture already in progress")
            return
        }
        isCapturing = true

        Task { @MainActor in
            defer { isCapturing = false }

            // Persist whatever is currently being edited
            commitCurrentModel()

            // Hide our own window so it never ends up in the screenshot,
            // then give the window server a moment to redraw.
            let wasVisible = window?.isVisible ?? false
            if wasVisible {
                window?.orderOut(nil)
                try? await Task.sleep(for: .milliseconds(150))
            }

            do {
                let result = try await ScreenCaptureService.shared.captureFrontmostWindow()
                let capture = try store.addCapture(result)
                StatusOverlay.shared.showBrief(message: "Screenshot \(capture.index) captured")
                open(capture: capture, isNew: true)
            } catch ScreenCaptureError.permissionDenied {
                StatusOverlay.shared.showBrief(message: "Allow Screen Recording for AIHelper, then try again")
                if wasVisible { window?.makeKeyAndOrderFront(nil) }
            } catch {
                logger.error("Capture failed: \(error.localizedDescription)")
                StatusOverlay.shared.showBrief(message: error.localizedDescription)
                if wasVisible { window?.makeKeyAndOrderFront(nil) }
            }
        }
    }

    /// Opens the most recent capture of the session (or captures one if empty).
    func showSession() {
        if let current = model?.capture, window?.isVisible == true {
            open(capture: current, isNew: false)
            return
        }
        if let last = store.session.captures.last {
            open(capture: last, isNew: false)
        } else {
            captureAndAnnotate()
        }
    }

    /// Hotkey entry point (⌃⌥⌘⇧D): exports right away and puts the hand-off on
    /// the clipboard. With the review setting enabled it shows the review tab
    /// first and ↩ there does the export.
    func reviewAndFinish() {
        // A note popup that is still open is saved first (stops recording too)
        QuickCaptureController.shared.finishPendingNote()

        guard !store.session.captures.isEmpty else {
            StatusOverlay.shared.showBrief(message: ScreenshotNotesError.emptySession.localizedDescription)
            return
        }
        if ScreenshotNotesStore.reviewBeforeExportEnabled {
            openReview()
        } else {
            ScreenshotNotesLog.log("Exporting directly, review step skipped (\(store.session.captures.count) captures)")
            exportNow(revealInFinder: false)
        }
    }

    /// Shows the review tab; the export happens via "Export now" (↩).
    func openReview() {
        QuickCaptureController.shared.finishPendingNote()
        guard !store.session.captures.isEmpty else {
            StatusOverlay.shared.showBrief(message: ScreenshotNotesError.emptySession.localizedDescription)
            return
        }
        let capture = model?.capture ?? store.session.captures.last!
        open(capture: capture, isNew: false, tab: .preview, reviewing: true)
        ScreenshotNotesLog.log("Review before export opened (\(store.session.captures.count) captures)")
    }

    /// Re-reads a capture from the store if the editor currently shows it
    /// (used when a note popup saves while the editor is open).
    func reloadIfShowing(captureID: UUID) {
        guard let current = model, current.capture.id == captureID,
              window?.isVisible == true,
              let fresh = store.capture(withID: captureID) else { return }
        open(capture: fresh, isNew: false, tab: current.tab, reviewing: current.isReviewingForExport)
    }

    /// Commit, export notes.md/PDF/ZIP, put the hand-off on the clipboard and start a new session.
    /// Waits for dictations that are still transcribing in the background first.
    func exportNow(revealInFinder: Bool = true) {
        commitCurrentModel()
        Task { @MainActor in
            await waitForLateDictations()
            finishAndClose(revealInFinder: revealInFinder)
        }
    }

    private func waitForLateDictations() async {
        if QuickCaptureController.shared.pendingTranscriptions > 0 {
            StatusOverlay.shared.showBrief(message: "Finishing dictation…")
            await QuickCaptureController.shared.waitForPendingTranscriptions()
        }
    }

    private func finishAndClose(revealInFinder: Bool = true) {
        do {
            let handoff = try store.finishSession(revealInFinder: revealInFinder)
            let message: String
            switch ScreenshotNotesStore.HandoffFormat.current {
            case .zip: message = "ZIP in clipboard – ⌘V to hand it to your agent (\(handoff.lastPathComponent)) · kept in History"
            case .pdf: message = "PDF in clipboard – ⌘V to hand it to your agent (\(handoff.lastPathComponent)) · kept in History"
            case .markdown: message = "Markdown in clipboard – ⌘V to paste it into your agent · kept in History"
            }
            StatusOverlay.shared.showBrief(message: message)
            logger.info("Session exported, hand-off: \(handoff.path)")
            closeWindow()
        } catch {
            StatusOverlay.shared.showBrief(message: error.localizedDescription)
        }
    }

    /// Asks where to save and writes a PDF of the whole session there.
    func exportPDF() {
        commitCurrentModel()
        guard !store.session.captures.isEmpty else {
            StatusOverlay.shared.showBrief(message: ScreenshotNotesError.emptySession.localizedDescription)
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Screenshot Notes as PDF"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.directoryURL = store.sessionFolder
        let sessionName = store.sessionFolder.lastPathComponent
        panel.nameFieldStringValue = "screenshot-notes-\(sessionName).pdf"

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try self.store.writePDF(to: url)
                StatusOverlay.shared.showBrief(message: "PDF exported")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                StatusOverlay.shared.showBrief(message: error.localizedDescription)
            }
        }
        if let parent = window, parent.isVisible {
            panel.beginSheetModal(for: parent, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    // MARK: - Send to agent

    func sendToLocalClaudeCode() {
        commitCurrentModel()
        Task { @MainActor in
            await waitForLateDictations()
            do {
                try await AgentHandoffService.sendToLocalClaudeCode(store: store)
                StatusOverlay.shared.showBrief(message: "Claude Code started in the session folder")
            } catch {
                StatusOverlay.shared.showBrief(message: error.localizedDescription)
            }
        }
    }

    func sendToVM() {
        commitCurrentModel()
        Task { @MainActor in
            await waitForLateDictations()
            StatusOverlay.shared.showBrief(message: "Uploading session to VM…")
            do {
                let host = try await AgentHandoffService.sendToVM(store: store)
                StatusOverlay.shared.showBrief(message: "Sent to \(host) – prompt typed in iTerm")
            } catch {
                StatusOverlay.shared.showBrief(message: error.localizedDescription)
            }
        }
    }

    /// Asks where to save and writes a ZIP of the whole session there.
    func exportZip() {
        commitCurrentModel()
        guard !store.session.captures.isEmpty else {
            StatusOverlay.shared.showBrief(message: ScreenshotNotesError.emptySession.localizedDescription)
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Screenshot Notes as ZIP"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.directoryURL = ScreenshotNotesStore.rootFolder
        panel.nameFieldStringValue = store.zipURL.lastPathComponent

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let zip = try self.store.writeZip(to: url)
                self.store.copyHandoffToClipboard(fileURL: zip)
                StatusOverlay.shared.showBrief(message: "ZIP exported and copied")
                NSWorkspace.shared.activateFileViewerSelecting([zip])
            } catch {
                StatusOverlay.shared.showBrief(message: error.localizedDescription)
            }
        }
        if let parent = window, parent.isVisible {
            panel.beginSheetModal(for: parent, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    // MARK: - Window management

    func open(capture: ScreenshotCapture, isNew: Bool, tab: ScreenshotAnnotationModel.Tab? = nil, reviewing: Bool? = nil) {
        guard let image = store.image(for: capture) else {
            StatusOverlay.shared.showBrief(message: "Could not load screenshot")
            return
        }

        // Switching captures inside the same window: save the previous one
        let previous = model
        if let existing = model, existing.capture.id != capture.id {
            commitCurrentModel()
        }

        let model = ScreenshotAnnotationModel(capture: capture, image: image, isNew: isNew)
        // Keep the review state when jumping between captures
        model.tab = tab ?? (previous.map { $0.isReviewingForExport ? .preview : .annotate } ?? .annotate)
        model.isReviewingForExport = reviewing ?? (previous?.isReviewingForExport ?? false)
        self.model = model

        let rootView = ScreenshotAnnotationView(
            model: model,
            onSave: { [weak self] in
                self?.commitCurrentModel()
                self?.closeWindow()
            },
            onDiscard: { [weak self] in
                self?.discardCurrent()
            },
            onFinish: { [weak self] in
                self?.exportNow()
            },
            onCopyMarkdown: { [weak self] in
                self?.commitCurrentModel()
                self?.store.copyMarkdownToClipboard()
                StatusOverlay.shared.showBrief(message: "Markdown copied (\(self?.store.session.captures.count ?? 0) screenshots)")
            },
            onExportPDF: { [weak self] in
                self?.exportPDF()
            },
            onExportZip: { [weak self] in
                self?.exportZip()
            },
            onSendLocal: { [weak self] in
                self?.sendToLocalClaudeCode()
            },
            onSendVM: { [weak self] in
                self?.sendToVM()
            },
            onOpenCapture: { [weak self] other in
                // Jump into the annotate view to edit; review state is kept for the way back
                self?.open(capture: other, isNew: false, tab: .annotate)
            },
            onNewCapture: { [weak self] in
                self?.captureAndAnnotate()
            }
        )

        let window = self.window ?? makeWindow()
        window.title = "Screenshot \(capture.index) – \(capture.displayTitle)"
        window.contentView = NSHostingView(rootView: rootView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("ScreenshotAnnotationWindow")
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        self.window = window
        logger.info("Created screenshot annotation window")
        return window
    }

    func closeWindow() {
        window?.close()
    }

    // MARK: - Commit / discard

    private func commitCurrentModel() {
        guard let model, !model.isDiscarded else { return }
        model.dictation.cancel()
        store.update(model.capture)
        model.markSaved()
    }

    private func discardCurrent() {
        guard let model else { return }
        model.markDiscarded()
        let removedIndex = model.capture.index
        let tab = model.tab
        let reviewing = model.isReviewingForExport
        store.delete(model.capture)

        let remaining = store.session.captures
        guard !remaining.isEmpty else {
            StatusOverlay.shared.showBrief(message: "Screenshot removed – session is empty now")
            closeWindow()
            return
        }
        StatusOverlay.shared.showBrief(message: "Screenshot \(removedIndex) removed – \(remaining.count) left, renumbered")
        // Show the capture that moved into the removed slot (or the last one)
        let next = remaining[min(removedIndex, remaining.count) - 1]
        open(capture: next, isNew: false, tab: tab, reviewing: reviewing)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Closing via the red button keeps the notes
        commitCurrentModel()
        model = nil
        // Drop the hosting view so the SwiftUI hierarchy is torn down
        window?.contentView = nil
    }
}
