import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "DevMachinesWindow")

/// Manages the Development Machines window as a floating panel.
class DevelopmentMachinesWindowController {
    static let shared = DevelopmentMachinesWindowController()

    private var window: NSWindow?
    private var isCreatingWindow = false

    func showWindow() {
        guard !isCreatingWindow else {
            logger.warning("Window creation already in progress")
            return
        }

        if let existingWindow = window, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        isCreatingWindow = true
        defer { isCreatingWindow = false }

        let contentView = DevelopmentMachinesView()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Development Machines"
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.setFrameAutosaveName("DevelopmentMachinesWindow")
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        logger.info("Development Machines window created and shown")
    }

    func hideWindow() {
        window?.close()
    }

    func toggleWindow() {
        if let window = window, window.isVisible {
            hideWindow()
        } else {
            showWindow()
        }
    }
}
