import AppKit
import AVFoundation
import ApplicationServices

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
}
