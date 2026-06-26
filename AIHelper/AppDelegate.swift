import AppKit
import SwiftUI
import ApplicationServices
import Combine
import os.log

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Debounce interval for hotkey presses to prevent double-triggering
    private var lastHotkeyTime: Date = .distantPast
    private let hotkeyDebounceInterval: TimeInterval = 0.3

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hyper key (Caps Lock → ⌃⌥⌘⇧) is ON by default for new installs.
        // An explicit user toggle is stored in the standard domain and overrides this.
        UserDefaults.standard.register(defaults: [HyperKeyManager.enabledKey: true])

        // Check all permissions
        Task { @MainActor in
            PermissionManager.shared.checkAllPermissions()
        }

        // Register global shortcuts
        registerShortcuts()

        // Start the Caps Lock hyper key if the user enabled it
        HyperKeyManager.shared.startIfEnabled()

        // Drive the menu-bar icon ourselves. MenuBarExtra on recent macOS does not re-render
        // its label/systemImage when observed state changes, so we update the status item's
        // image directly (the mic fills in while keep-awake is on).
        MenuBarIconController.shared.start()

        // First-launch welcome: explain the Hyper Key (which remaps Caps Lock) and walk the
        // user through granting the permissions it needs. Slight delay so the menu bar is up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            WelcomeWindowController.shared.showIfNeeded()
        }
    }

    func registerShortcuts() {
        print("Registering keyboard shortcuts...")
        GlobalKeyboardShortcut.shared.unregister() // Unregister first to avoid duplicates

        GlobalKeyboardShortcut.shared.registerMultiple([
            // Ctrl+Option+Cmd+Shift+R: Toggle Recording
            (.recording, { [weak self] in
                print("Recording hotkey triggered!")
                self?.handleRecordingHotkey()
            }),

            // Ctrl+Option+Cmd+Shift+E: Email Reply (record response to selected email)
            (.emailReply, { [weak self] in
                print("Email reply hotkey triggered!")
                self?.handleEmailReplyHotkey()
            }),

            // Ctrl+Option+Cmd+Shift+T: Casual Message (record and rewrite as casual text)
            (.casualMessage, { [weak self] in
                print("Casual message hotkey triggered!")
                self?.handleCasualMessageHotkey()
            }),

            // Escape: Cancel Processing (only when transcribing/formatting)
            (.cancelProcessing, { [weak self] in
                self?.handleCancelHotkey()
            }),

            // Ctrl+Option+Cmd+Shift+S: Send Screenshot to VM
            (.sendScreenshot, { [weak self] in
                print("Screenshot transfer hotkey triggered!")
                self?.handleScreenshotHotkey()
            }),

            // Ctrl+Option+Cmd+Shift+C: Clipboard History
            (.clipboardHistory, {
                print("Clipboard history hotkey triggered!")
                Task { @MainActor in
                    ClipboardHistoryWindowController.shared.toggleWindow()
                }
            })
        ])

        print("Shortcuts registered:")
        print("  - Ctrl+Option+Cmd+Shift+R: Toggle Recording")
        print("  - Ctrl+Option+Cmd+Shift+E: Email Reply")
        print("  - Ctrl+Option+Cmd+Shift+T: Casual Message")
        print("  - Ctrl+Option+Cmd+Shift+S: Send Screenshot to VM")
        print("  - Ctrl+Option+Cmd+Shift+C: Clipboard History")
        print("  - Escape: Cancel Processing")
    }

    private func handleRecordingHotkey() {
        print("handleRecordingHotkey called")
        // Debounce rapid key presses
        let now = Date()
        guard now.timeIntervalSince(lastHotkeyTime) >= hotkeyDebounceInterval else {
            print("Hotkey debounced (too fast)")
            return
        }
        lastHotkeyTime = now

        Task { @MainActor in
            let manager = AppState.shared.recordingManager
            // Ignore if we're still processing (transcribing/formatting)
            if manager.isTranscribing || manager.isFormatting {
                print("Still processing, ignoring hotkey")
                return
            }
            print("Toggling recording...")
            manager.toggleRecording()
        }
    }

    private func handleCasualMessageHotkey() {
        print("handleCasualMessageHotkey called")
        // Debounce rapid key presses
        let now = Date()
        guard now.timeIntervalSince(lastHotkeyTime) >= hotkeyDebounceInterval else {
            print("Hotkey debounced (too fast)")
            return
        }
        lastHotkeyTime = now

        Task { @MainActor in
            let manager = AppState.shared.recordingManager
            // Ignore if we're still processing (transcribing/formatting)
            if manager.isTranscribing || manager.isFormatting {
                print("Still processing, ignoring hotkey")
                return
            }
            print("Toggling casual message recording...")
            manager.toggleCasualMessageRecording()
        }
    }

    private func handleEmailReplyHotkey() {
        print("handleEmailReplyHotkey called")
        // Debounce rapid key presses
        let now = Date()
        guard now.timeIntervalSince(lastHotkeyTime) >= hotkeyDebounceInterval else {
            print("Hotkey debounced (too fast)")
            return
        }
        lastHotkeyTime = now

        Task { @MainActor in
            let manager = AppState.shared.recordingManager
            // Ignore if we're still processing (transcribing/formatting)
            if manager.isTranscribing || manager.isFormatting {
                print("Still processing, ignoring hotkey")
                return
            }
            // toggleRecording handles both start and stop - mode is only used when starting
            print("Toggling email recording...")
            manager.toggleRecording(mode: .email)
        }
    }

    private func handleCancelHotkey() {
        print("handleCancelHotkey called")
        Task { @MainActor in
            let manager = AppState.shared.recordingManager
            // Only cancel if we're actually processing
            if manager.isTranscribing || manager.isFormatting {
                print("Cancelling processing...")
                manager.cancelProcessing()
            } else {
                print("Not processing, ignoring cancel hotkey")
            }
        }
    }

    private func handleScreenshotHotkey() {
        print("handleScreenshotHotkey called")

        Task { @MainActor in
            do {
                // Show "Uploading..." status
                StatusOverlay.shared.showBrief(message: "Uploading screenshot...")

                let result = try await ScreenshotTransferService.shared.transferClipboardScreenshot()

                // Show success feedback
                StatusOverlay.shared.showBrief(message: "Sent to \(result.hostAlias)")
                print("Screenshot transfer succeeded: sent to \(result.hostAlias) at \(result.remotePath)")

            } catch {
                // Show error feedback
                let errorMessage = error.localizedDescription
                StatusOverlay.shared.showBrief(message: errorMessage)
                print("========== SCREENSHOT TRANSFER FAILED ==========")
                print("Error: \(errorMessage)")
                print("Full error: \(error)")
                print("================================================")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // So the onboarding window closing on quit (e.g. the Input Monitoring "Quit & Reopen")
        // resumes next launch instead of being marked as dismissed.
        WelcomeWindowController.appIsTerminating = true
        GlobalKeyboardShortcut.shared.unregister()
        // Restore normal Caps Lock so it isn't left remapped after we quit.
        HyperKeyManager.shared.resetMapping()
    }
}

/// Owns the menu-bar status-item image. `MenuBarExtra` renders its icon once and does not
/// reactively update it on recent macOS, so we locate its underlying status button and set
/// the image ourselves whenever recording / transcribing / keep-awake state changes.
///
/// While keep-awake is active the mic fills in (`mic` → `mic.fill`) — a glanceable "the
/// screen won't lock" indicator, in the spirit of the classic Caffeine app's full cup.
@MainActor
final class MenuBarIconController {
    static let shared = MenuBarIconController()

    private var cancellables = Set<AnyCancellable>()
    private weak var button: NSStatusBarButton?

    func start() {
        let appState = AppState.shared
        // Re-render on any of the three state sources.
        for publisher in [
            CaffeineManager.shared.objectWillChange.eraseToAnyPublisher(),
            appState.audioRecorder.objectWillChange.eraseToAnyPublisher(),
            appState.recordingManager.objectWillChange.eraseToAnyPublisher(),
        ] {
            publisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    // objectWillChange fires before the value updates; hop once more so we
                    // read the new state.
                    DispatchQueue.main.async { self?.update() }
                }
                .store(in: &cancellables)
        }
        locateButton(retries: 24)
    }

    /// The status button may not exist yet at launch; retry briefly until MenuBarExtra
    /// has created it.
    private func locateButton(retries: Int) {
        if let b = Self.findStatusButton() {
            button = b
            update()
            return
        }
        guard retries > 0 else {
            logger.error("MenuBarIconController: status button NOT found after retries; windows=\(NSApp.windows.map { String(describing: type(of: $0)) }.joined(separator: ","))")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.locateButton(retries: retries - 1)
        }
    }

    private static func findStatusButton() -> NSStatusBarButton? {
        for window in NSApp.windows {
            if let b = find(in: window.contentView) { return b }
        }
        return nil
    }

    private static func find(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let b = view as? NSStatusBarButton { return b }
        for sub in view.subviews {
            if let b = find(in: sub) { return b }
        }
        return nil
    }

    private func update() {
        if button == nil { button = Self.findStatusButton() }
        guard let button else { return }

        let appState = AppState.shared
        let symbol: String
        if appState.recordingManager.isTranscribing {
            symbol = "ellipsis.circle"
        } else if appState.audioRecorder.isRecording {
            symbol = "record.circle.fill"
        } else if CaffeineManager.shared.isActive {
            // Keep-awake on: fill the mic — like Caffeine's full cup — so the menu bar
            // shows at a glance that the screen won't lock.
            symbol = "mic.fill"
        } else {
            symbol = "mic"
        }

        // Template image so it renders monochrome and adapts to the menu bar (light/dark),
        // matching every other status item.
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AIHelper")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = nil
    }
}

private let logger = Logger(subsystem: "com.aihelper.app", category: "MenuBarIcon")
