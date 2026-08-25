import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "ScreenshotHistoryWindow")

/// Window listing the recent screenshot sessions (see `ScreenshotHistoryView`).
@MainActor
final class ScreenshotHistoryWindowController {
    static let shared = ScreenshotHistoryWindowController()

    private var window: NSWindow?

    func showWindow() {
        ScreenshotHistoryStore.shared.refresh()

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Screenshot Notes History"
        window.contentView = NSHostingView(rootView: ScreenshotHistoryView())
        window.center()
        window.setFrameAutosaveName("ScreenshotHistoryWindow")
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        logger.info("Screenshot history window shown")
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }
}
