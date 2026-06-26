import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "ClipboardHistoryWindow")

@MainActor
class ClipboardHistoryWindowController {
    static let shared = ClipboardHistoryWindowController()

    private var window: NSWindow?
    private var isCreatingWindow = false

    func showWindow() {
        guard !isCreatingWindow else {
            logger.warning("Window creation already in progress")
            return
        }

        if let existingWindow = window {
            if existingWindow.isMiniaturized {
                logger.debug("Restoring minimized window")
                existingWindow.deminiaturize(nil)
            }

            if existingWindow.isVisible || existingWindow.isMiniaturized {
                logger.debug("Bringing existing window to front")
                existingWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
        }

        isCreatingWindow = true
        defer { isCreatingWindow = false }

        logger.info("Creating new clipboard history window")

        let contentView = ClipboardHistoryView()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Clipboard History"
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.setFrameAutosaveName("ClipboardHistoryWindow")
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false

        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        logger.info("Clipboard history window created and shown")
    }

    func hideWindow() {
        logger.debug("Hiding clipboard history window")
        window?.close()
    }

    func toggleWindow() {
        if let window = window, window.isVisible && !window.isMiniaturized {
            hideWindow()
        } else {
            showWindow()
        }
    }
}
