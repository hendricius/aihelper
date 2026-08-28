import AppKit
import Combine
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "MenuBar")

/// Owns the menu-bar status item and the popover hanging off it.
///
/// This used to be a SwiftUI `MenuBarExtra(.window)`. Two things made that a poor fit:
/// it aligns its window's *left* edge with the status item instead of centring under it
/// (a 380pt panel under a 32pt item ends up ~175pt off), and it renders its icon once
/// and does not update it when observed state changes, which needed a separate controller
/// that hunted the underlying `NSStatusBarButton` through the view hierarchy.
///
/// An `NSStatusItem` plus an `NSPopover` fixes both: `show(relativeTo:of:preferredEdge:)`
/// centres the popover under the button and points the arrow at it, and the image is ours
/// to set directly.
@MainActor
final class MenuBarController {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()

    /// Builds the status item and popover. Call once, after the app finishes launching.
    func start() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.setAccessibilityLabel("AIHelper")
        statusItem = item

        let appState = AppState.shared
        let content = ContentView()
            .environmentObject(appState.transcriptionStore)
            .environmentObject(appState.audioRecorder)
            .environmentObject(appState.recordingManager)
            .environmentObject(appState.permissionManager)
            .environmentObject(appState.failedRequestStore)

        let panel = NSPopover()
        panel.contentViewController = NSHostingController(rootView: content)
        panel.contentSize = NSSize(width: 380, height: 620)
        // Closes as soon as the user clicks elsewhere, like every other menu-bar app.
        panel.behavior = .transient
        panel.animates = false
        popover = panel

        observeState()
        updateIcon()
        logger.info("Menu bar status item created")
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(sender)
            return
        }

        // Without activating, the popover's text fields cannot take focus.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// Opens the popover if it is closed. Used by anything that wants to surface the app.
    func showPopover() {
        guard let popover, !popover.isShown else { return }
        togglePopover(nil)
    }

    func closePopover() {
        popover?.performClose(nil)
    }

    // MARK: - Icon

    private func observeState() {
        let appState = AppState.shared
        for publisher in [
            CaffeineManager.shared.objectWillChange.eraseToAnyPublisher(),
            appState.audioRecorder.objectWillChange.eraseToAnyPublisher(),
            appState.recordingManager.objectWillChange.eraseToAnyPublisher(),
        ] {
            publisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    // objectWillChange fires before the value lands; hop once more so we
                    // read the new state.
                    DispatchQueue.main.async { self?.updateIcon() }
                }
                .store(in: &cancellables)
        }
    }

    /// While keep-awake is active the mic fills in (`mic` → `mic.fill`) — a glanceable
    /// "the screen won't lock" indicator, in the spirit of Caffeine's full cup.
    private func updateIcon() {
        guard let button = statusItem?.button else { return }

        let appState = AppState.shared
        let symbol: String
        if appState.recordingManager.isTranscribing {
            symbol = "ellipsis.circle"
        } else if appState.audioRecorder.isRecording {
            symbol = "record.circle.fill"
        } else if CaffeineManager.shared.isActive {
            symbol = "mic.fill"
        } else {
            symbol = "mic"
        }

        // Template image so it renders monochrome and follows the menu bar in light and
        // dark, matching every other status item.
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AIHelper")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = nil
    }
}
