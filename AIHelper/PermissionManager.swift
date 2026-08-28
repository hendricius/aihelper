import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import Speech

@MainActor
class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    @Published var hasAccessibilityPermission = false
    @Published var hasMicrophonePermission = false

    func checkAllPermissions() {
        checkAccessibilityPermission()
        checkMicrophonePermission()
    }

    func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrusted()
        hasAccessibilityPermission = trusted
        print("Accessibility permission: \(trusted ? "GRANTED" : "DENIED")")
        print("hasAccessibilityPermission set to: \(hasAccessibilityPermission)")
    }

    func checkMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            hasMicrophonePermission = true
            print("Microphone permission: GRANTED")
        case .notDetermined:
            hasMicrophonePermission = false
            print("Microphone permission: NOT DETERMINED")
        case .denied, .restricted:
            hasMicrophonePermission = false
            print("Microphone permission: DENIED")
        @unknown default:
            hasMicrophonePermission = false
        }
    }

    func requestAccessibilityPermission() {
        print("requestAccessibilityPermission() called - triggering system prompt")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let result = AXIsProcessTrustedWithOptions(options as CFDictionary)
        print("AXIsProcessTrustedWithOptions returned: \(result)")

        // Check again after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.checkAccessibilityPermission()
        }
    }

    func requestMicrophonePermission() {
        print("requestMicrophonePermission() called")
        let currentStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        print("Current microphone status before request: \(currentStatus.rawValue)")

        if currentStatus == .notDetermined {
            print("Status is notDetermined, requesting access...")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.hasMicrophonePermission = granted
                    print("Microphone permission after request: \(granted ? "GRANTED" : "DENIED")")
                }
            }
        } else if currentStatus == .denied {
            print("Status is denied, opening System Settings...")
            openMicrophoneSettings()
        } else if currentStatus == .authorized {
            print("Already authorized")
            hasMicrophonePermission = true
        }
    }

    func openAccessibilitySettings() {
        // Try to trigger the prompt first
        requestAccessibilityPermission()

        // Also open System Settings directly since the prompt may not appear if previously denied
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Full audit (Settings → Permissions)

    /// Every permission the app depends on, refreshed by `refreshAudit()`.
    @Published var checks: [PermissionCheck] = []

    /// "All 6 granted" / "4 of 6 granted", for the sidebar subtitle.
    var auditSummary: String { PermissionAudit.summary(for: checks) }

    /// Permissions that are missing and actually block a feature.
    var blockingChecks: [PermissionCheck] { checks.filter { $0.state.isBlocking } }

    /// Re-reads every permission. Preflight only — this never shows a system prompt, so it
    /// is safe to call whenever the page appears or the app comes back to the front.
    func refreshAudit() {
        checks = PermissionAudit.checkAll()
        // Keep the two long-standing flags in step for the rest of the app.
        hasAccessibilityPermission = checks.first { $0.id == .accessibility }?.state == .granted
        hasMicrophonePermission = checks.first { $0.id == .microphone }?.state == .granted
    }

    /// Asks macOS for the permission where an API exists for it, then refreshes. Once a
    /// permission has been refused the system prompt no longer appears, so for anything
    /// already denied this opens System Settings instead.
    func request(_ kind: PermissionCheck.Kind) {
        let current = checks.first { $0.id == kind }?.state ?? PermissionAudit.check(kind).state
        guard kind.canPromptDirectly, current == .notDetermined else {
            openSettings(for: kind)
            return
        }

        switch kind {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refreshAudit() }
            }
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
            scheduleRefresh()
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
            scheduleRefresh()
        case .speechRecognition:
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in
                Task { @MainActor in self?.refreshAudit() }
            }
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
            scheduleRefresh()
        case .automation:
            openSettings(for: kind)
        }
    }

    /// Opens the System Settings pane that grants `kind`.
    func openSettings(for kind: PermissionCheck.Kind) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsPane)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// A plain-text report of the current state, for pasting into a bug report.
    func diagnosticsReport() -> String {
        let info = Bundle.main.infoDictionary
        return PermissionAudit.diagnosticsReport(
            for: checks,
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?"
        )
    }

    /// System prompts resolve asynchronously and the preflight APIs lag slightly behind them.
    private func scheduleRefresh() {
        Task { @MainActor [weak self] in
            for delay in [0.6, 1.5, 3.0] {
                try? await Task.sleep(for: .seconds(delay))
                self?.refreshAudit()
            }
        }
    }
}
