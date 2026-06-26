import SwiftUI
import AppKit

class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    func showSettings() {
        print("SettingsWindowController: showSettings called")

        // Activate app first to ensure windows can be shown
        NSApp.activate(ignoringOtherApps: true)

        if let existingWindow = window, existingWindow.isVisible {
            print("SettingsWindowController: Bringing existing window to front")
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        print("SettingsWindowController: Creating new settings window")

        let settingsView = SettingsView()
            .environmentObject(AppState.shared.transcriptionStore)

        let hostingController = NSHostingController(rootView: settingsView)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        newWindow.contentViewController = hostingController
        newWindow.title = "AIHelper Settings"
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.level = .floating  // Ensure it appears above other windows

        // Handle window close
        newWindow.delegate = WindowDelegate.shared

        self.window = newWindow

        newWindow.makeKeyAndOrderFront(nil)

        print("SettingsWindowController: Window created and shown")
    }

    func windowWillClose() {
        NSLog("SettingsWindowController: Window closed")
        window = nil
    }
}

class WindowDelegate: NSObject, NSWindowDelegate {
    static let shared = WindowDelegate()

    func windowWillClose(_ notification: Notification) {
        SettingsWindowController.shared.windowWillClose()
    }
}
