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

        ScreenshotNotesLog.installUncaughtExceptionHandler()

        // Check all permissions
        Task { @MainActor in
            PermissionManager.shared.checkAllPermissions()
            // Restores an open screenshot session and drops history entries
            // beyond the configured limit
            ScreenshotHistoryStore.shared.refreshAndPrune()
        }

        // Register global shortcuts
        registerShortcuts()

        // Start the Caps Lock hyper key if the user enabled it
        HyperKeyManager.shared.startIfEnabled()

        // Build the status item and its popover (see MenuBarController).
        MenuBarController.shared.start()

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
            }),

            // Ctrl+Option+Cmd+Shift+A: Capture the frontmost window and annotate it
            (.annotateScreenshot, {
                print("Annotate screenshot hotkey triggered!")
                Task { @MainActor in
                    ScreenshotAnnotationWindowController.shared.captureAndAnnotate()
                }
            }),

            // Ctrl+Option+Cmd+Shift+D: Export the session, hand-off to clipboard
            (.finishScreenshotSession, {
                print("Finish screenshot session hotkey triggered!")
                Task { @MainActor in
                    ScreenshotAnnotationWindowController.shared.reviewAndFinish()
                }
            }),

            // Ctrl+Option+Cmd+Shift+M: Review/edit the session before exporting
            (.reviewScreenshotSession, {
                print("Review screenshot session hotkey triggered!")
                Task { @MainActor in
                    ScreenshotAnnotationWindowController.shared.openReview()
                }
            })
        ])

        print("Shortcuts registered:")
        print("  - Ctrl+Option+Cmd+Shift+R: Toggle Recording")
        print("  - Ctrl+Option+Cmd+Shift+E: Email Reply")
        print("  - Ctrl+Option+Cmd+Shift+T: Casual Message")
        print("  - Ctrl+Option+Cmd+Shift+S: Send Screenshot to VM")
        print("  - Ctrl+Option+Cmd+Shift+C: Clipboard History")
        print("  - Ctrl+Option+Cmd+Shift+A: Annotate Screenshot")
        print("  - Ctrl+Option+Cmd+Shift+D: Export Screenshot Notes")
        print("  - Ctrl+Option+Cmd+Shift+M: Review Screenshot Notes")
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

