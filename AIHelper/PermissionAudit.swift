import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import Speech

/// Where a permission stands right now.
enum PermissionState: String, Equatable {
    /// Granted — the feature behind it works.
    case granted
    /// Explicitly refused, or revoked in System Settings. Only the user can undo this.
    case denied
    /// Never asked. The app can still bring up the system prompt.
    case notDetermined
    /// Nothing to grant on this Mac (e.g. the app the permission targets isn't installed).
    case notApplicable

    var isBlocking: Bool { self == .denied || self == .notDetermined }
}

/// One permission the app depends on, and what breaks without it.
struct PermissionCheck: Identifiable, Equatable {
    let id: Kind
    let state: PermissionState
    /// Extra context for states that need explaining, e.g. which app was probed.
    let detail: String?

    enum Kind: String, CaseIterable, Identifiable {
        case microphone
        case accessibility
        case inputMonitoring
        case speechRecognition
        case screenRecording
        case automation

        var id: String { rawValue }

        var title: String {
            switch self {
            case .microphone: return "Microphone"
            case .accessibility: return "Accessibility"
            case .inputMonitoring: return "Input Monitoring"
            case .speechRecognition: return "Speech Recognition"
            case .screenRecording: return "Screen Recording"
            case .automation: return "Automation (Apple Events)"
            }
        }

        var symbol: String {
            switch self {
            case .microphone: return "mic"
            case .accessibility: return "accessibility"
            case .inputMonitoring: return "keyboard"
            case .speechRecognition: return "waveform"
            case .screenRecording: return "rectangle.dashed.badge.record"
            case .automation: return "app.connected.to.app.below.fill"
            }
        }

        /// What stops working while this is missing — the reason the row matters.
        var purpose: String {
            switch self {
            case .microphone:
                return "Recording audio. Without it, nothing can be transcribed."
            case .accessibility:
                return "The global ⌃⌥⌘⇧ shortcuts, and inserting text at your cursor."
            case .inputMonitoring:
                return "The built-in Hyper Key (Caps Lock → ⌃⌥⌘⇧)."
            case .speechRecognition:
                return "Wake word and stop word. Recognition runs locally on your Mac."
            case .screenRecording:
                return "Screenshot Notes — capturing the window in front of you."
            case .automation:
                return "Reading the browser tab URL for a capture, and the iTerm hand-off to an agent."
            }
        }

        /// The System Settings › Privacy & Security pane that grants it.
        var settingsPane: String {
            switch self {
            case .microphone: return "Privacy_Microphone"
            case .accessibility: return "Privacy_Accessibility"
            case .inputMonitoring: return "Privacy_ListenEvent"
            case .speechRecognition: return "Privacy_SpeechRecognition"
            case .screenRecording: return "Privacy_ScreenCapture"
            case .automation: return "Privacy_Automation"
            }
        }

        /// True when the app itself can raise the system prompt; otherwise the user has to
        /// flip the switch in System Settings by hand.
        var canPromptDirectly: Bool {
            switch self {
            case .microphone, .accessibility, .speechRecognition, .screenRecording, .inputMonitoring:
                return true
            case .automation:
                // Apple Events prompts only when a script actually runs; there is no
                // preflight request API to call from here.
                return false
            }
        }
    }
}

/// Reads the current state of every permission the app depends on.
///
/// Everything here is preflight-only: no probe in this file shows a system prompt, so
/// opening the Permissions page never nags. Requesting is an explicit, separate action.
enum PermissionAudit {

    /// The apps the automation check probes, in priority order. The first one that is
    /// running decides the result; if none are running there is nothing to report.
    static let automationTargets = [
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "com.google.Chrome",
        "com.brave.Browser",
        "com.apple.Safari",
    ]

    static func checkAll() -> [PermissionCheck] {
        PermissionCheck.Kind.allCases.map { check($0) }
    }

    static func check(_ kind: PermissionCheck.Kind) -> PermissionCheck {
        switch kind {
        case .microphone:
            return PermissionCheck(id: kind, state: state(for: AVCaptureDevice.authorizationStatus(for: .audio)), detail: nil)
        case .accessibility:
            // AX has no "not determined": it is either in the list or it isn't.
            return PermissionCheck(id: kind, state: AXIsProcessTrusted() ? .granted : .denied, detail: nil)
        case .inputMonitoring:
            return PermissionCheck(id: kind, state: CGPreflightListenEventAccess() ? .granted : .denied, detail: nil)
        case .speechRecognition:
            return PermissionCheck(id: kind, state: state(for: SFSpeechRecognizer.authorizationStatus()), detail: nil)
        case .screenRecording:
            return PermissionCheck(id: kind, state: CGPreflightScreenCaptureAccess() ? .granted : .denied, detail: nil)
        case .automation:
            return automationCheck()
        }
    }

    // MARK: - State mapping

    static func state(for status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    static func state(for status: SFSpeechRecognizerAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    /// `AEDeterminePermissionToAutomateTarget` returns `noErr` when scripting the target is
    /// allowed, `errAEEventNotPermitted` when the user said no, and `procNotFound` when the
    /// target isn't running — which is not a permission problem.
    static func state(forAppleEventStatus status: OSStatus) -> PermissionState {
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(procNotFound): return .notApplicable
        default: return .denied
        }
    }

    // MARK: - Automation

    private static func automationCheck() -> PermissionCheck {
        let running = automationTargets.filter { isRunning(bundleID: $0) }
        guard let target = running.first else {
            return PermissionCheck(
                id: .automation,
                state: .notApplicable,
                detail: "None of the apps AIHelper scripts are running, so there is nothing to check."
            )
        }

        let status = appleEventPermission(forBundleID: target)
        let name = displayName(forBundleID: target) ?? target
        return PermissionCheck(id: .automation, state: state(forAppleEventStatus: status), detail: "Checked against \(name).")
    }

    /// Preflights Apple Events permission for one app without ever prompting.
    static func appleEventPermission(forBundleID bundleID: String) -> OSStatus {
        var target = AEAddressDesc()
        let created = bundleID.withCString { pointer -> OSErr in
            AECreateDesc(typeApplicationBundleID, pointer, strlen(pointer), &target)
        }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }

        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
    }

    private static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static func displayName(forBundleID bundleID: String) -> String? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .compactMap(\.localizedName)
            .first
    }

    // MARK: - Summary and diagnostics

    /// "All 6 granted" / "4 of 6 granted", ignoring rows that don't apply to this Mac.
    static func summary(for checks: [PermissionCheck]) -> String {
        let relevant = checks.filter { $0.state != .notApplicable }
        guard !relevant.isEmpty else { return "Nothing to check" }
        let granted = relevant.filter { $0.state == .granted }.count
        return granted == relevant.count
            ? "All \(relevant.count) granted"
            : "\(granted) of \(relevant.count) granted"
    }

    /// Plain-text report to paste into a bug report.
    static func diagnosticsReport(for checks: [PermissionCheck], appVersion: String, build: String) -> String {
        var lines = [
            "AIHelper permissions",
            "Version: \(appVersion) (\(build))",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Bundle: \(Bundle.main.bundleIdentifier ?? "unknown")",
            "Path: \(Bundle.main.bundlePath)",
            "",
        ]
        for check in checks {
            var line = "\(check.state == .granted ? "[x]" : "[ ]") \(check.id.title): \(check.state.rawValue)"
            if let detail = check.detail { line += " — \(detail)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
