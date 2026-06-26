import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics

/// One-time, first-launch onboarding. A short paged tour that introduces the app, explains
/// the built-in Hyper Key (which remaps Caps Lock), and — crucially — turns the painful
/// permission dance into a *live* checklist that ticks green the instant the user flips each
/// switch in System Settings, so the very first launch feels guided instead of broken.
final class WelcomeWindowController {
    static let shared = WelcomeWindowController()

    /// Bump the suffix if the onboarding content changes enough to re-show it.
    static let completedKey = "welcome_completed_v1"
    /// The step the user last reached, so onboarding resumes there after a restart.
    static let stepKey = "welcome_step"

    /// Set true while the app is quitting. Granting Input Monitoring makes macOS ask the user
    /// to "Quit & Reopen"; when that closes the onboarding window we must NOT treat it as the
    /// user dismissing onboarding — it should resume on next launch instead.
    static var appIsTerminating = false

    private var window: NSWindow?
    private init() {}

    var isComplete: Bool { UserDefaults.standard.bool(forKey: Self.completedKey) }

    /// Show the onboarding on first launch, or resume it if a previous run was interrupted
    /// (e.g. by the Input Monitoring restart) before the user finished or skipped.
    func showIfNeeded() {
        guard !isComplete else { return }
        show()
    }

    /// Replay onboarding from the very beginning (used by Settings → Developer).
    func replayFromStart() {
        UserDefaults.standard.set(0, forKey: Self.stepKey)
        UserDefaults.standard.set(false, forKey: Self.completedKey)
        show()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: OnboardingView { [weak self] in self?.complete() })
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 660),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.isMovableByWindowBackground = true
        win.contentViewController = hosting
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.delegate = WelcomeWindowDelegate.shared
        window = win
        win.makeKeyAndOrderFront(nil)
    }

    /// User explicitly finished or skipped — don't show onboarding again.
    fileprivate func complete() {
        markComplete()
        window?.close()
        window = nil
    }

    /// The window closed. If the app is quitting (e.g. the Input Monitoring "Quit & Reopen"),
    /// leave onboarding un-finished so it resumes at the saved step next launch. Otherwise the
    /// user closed it deliberately with the red button — treat that as done.
    fileprivate func windowClosed() {
        if !Self.appIsTerminating { markComplete() }
        window = nil
    }

    private func markComplete() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        UserDefaults.standard.set(0, forKey: Self.stepKey)
    }
}

final class WelcomeWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowDelegate()
    func windowWillClose(_ notification: Notification) {
        WelcomeWindowController.shared.windowClosed()
    }
}

// MARK: - Live permission state

/// Polls the three permissions onboarding cares about so the UI can reflect grants the
/// instant the user flips a switch in System Settings — no relaunch, no guessing.
@MainActor
final class OnboardingModel: ObservableObject {
    @Published var accessibility = false
    @Published var inputMonitoring = false
    @Published var microphone = false

    private var timer: Timer?

    var allGranted: Bool { accessibility && inputMonitoring && microphone }
    var grantedCount: Int { [accessibility, inputMonitoring, microphone].filter { $0 }.count }

    func startPolling() {
        refresh()
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer = t
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        accessibility = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        // Arm the Hyper Key the moment both of its permissions are present.
        if accessibility && inputMonitoring { HyperKeyManager.shared.armIfReady() }
    }

    // MARK: Grant actions (prompt + open the right Settings pane)

    func grantAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        openPane("Privacy_Accessibility")
    }

    func grantInputMonitoring() {
        _ = CGRequestListenEventAccess()
        openPane("Privacy_ListenEvent")
    }

    func grantMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in self.refresh() }
            }
        default:
            openPane("Privacy_Microphone")
        }
    }

    private func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Onboarding flow

struct OnboardingView: View {
    let onDone: () -> Void

    @StateObject private var model = OnboardingModel()
    // Resume where we left off if a previous run was interrupted (e.g. the Input Monitoring
    // "Quit & Reopen"). Persisted on every change below.
    @State private var step = UserDefaults.standard.integer(forKey: WelcomeWindowController.stepKey)

    private static let lastStep = 3
    private let violet = Color(red: 0.482, green: 0.361, blue: 0.902)
    private let blue = Color(red: 0.239, green: 0.482, blue: 0.941)

    var body: some View {
        VStack(spacing: 0) {
            // Step content
            Group {
                switch step {
                case 0: welcomeStep
                case 1: hyperKeyStep
                case 2: permissionsStep
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .opacity))
            .id(step)

            footer
        }
        .frame(width: 480, height: 660)
        .background(.background)
        .animation(.easeInOut(duration: 0.25), value: step)
        .onAppear {
            step = max(0, min(step, Self.lastStep))
            model.startPolling()
        }
        .onChange(of: step) { _, newStep in
            UserDefaults.standard.set(newStep, forKey: WelcomeWindowController.stepKey)
        }
        .onDisappear { model.stopPolling() }
    }

    // MARK: Steps

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Spacer().frame(height: 8)
            appMark
            VStack(spacing: 8) {
                Text("Welcome to AIHelper")
                    .font(.system(size: 24, weight: .bold))
                Text("Talk. AIHelper types it for you — and can polish it into a clean email or casual message, right from the menu bar.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 36)

            VStack(spacing: 10) {
                featureRow("mic.fill", "Record & transcribe", "A hotkey away, anywhere")
                featureRow("envelope.fill", "Email & message mode", "Reformat dictation with AI")
                featureRow("waveform", "Hands-free wake word", "Start talking to record")
                featureRow("cup.and.saucer.fill", "Keep Awake", "Stop your screen from locking")
            }
            .padding(.horizontal, 32)
            Spacer(minLength: 0)
        }
        .padding(.top, 28)
    }

    private var hyperKeyStep: some View {
        VStack(spacing: 18) {
            stepHeading("capslock", "Your Caps Lock, supercharged")

            HStack(spacing: 10) {
                keycap("⇪", "Caps Lock")
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                keycap("⌃⌥⌘⇧", "Hyper")
            }

            Text("AIHelper turns **Caps Lock** into a Hyper key. Hold it and tap a letter — no awkward four-finger chords, and no separate Hyperkey app.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 36)

            VStack(spacing: 8) {
                shortcutRow("R", "Record / stop", "mic.fill")
                shortcutRow("E", "Reformat as an email reply", "envelope.fill")
                shortcutRow("T", "Reformat as a casual message", "text.bubble.fill")
                shortcutRow("C", "Open clipboard history", "doc.on.clipboard.fill")
            }
            .padding(.horizontal, 32)

            Text("Caps Lock is remapped only while AIHelper runs — restored when you quit. Hold Shift to type capitals.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer(minLength: 0)
        }
        .padding(.top, 28)
    }

    private var permissionsStep: some View {
        VStack(spacing: 16) {
            stepHeading("lock.shield", "Two minutes of setup")

            Text(model.allGranted
                 ? "All set — you're good to go!"
                 : "Flip each switch in System Settings. This list ticks green automatically — no relaunch needed. ✨")
                .font(.callout)
                .foregroundStyle(model.allGranted ? Color.green : .secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 34)
                .animation(.easeInOut, value: model.allGranted)

            VStack(spacing: 10) {
                permissionRow(
                    granted: model.accessibility, icon: "accessibility",
                    title: "Accessibility",
                    why: "Run global shortcuts and the Hyper Key",
                    grant: model.grantAccessibility)
                permissionRow(
                    granted: model.inputMonitoring, icon: "keyboard",
                    title: "Input Monitoring",
                    why: "Detect Caps Lock for the Hyper Key",
                    grant: model.grantInputMonitoring)
                permissionRow(
                    granted: model.microphone, icon: "mic",
                    title: "Microphone",
                    why: "Record your voice to transcribe",
                    grant: model.grantMicrophone)
            }
            .padding(.horizontal, 28)

            if !model.inputMonitoring {
                Label("macOS may ask you to quit & reopen after granting Input Monitoring — that's expected. Setup picks up right here.", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .transition(.opacity)
            }

            Text("AIHelper never records or sends anything until you press record. You bring your own API key.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer(minLength: 0)
        }
        .padding(.top, 28)
        .animation(.easeInOut, value: model.inputMonitoring)
    }

    private var doneStep: some View {
        VStack(spacing: 18) {
            Spacer().frame(height: 8)
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [violet, blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 80, height: 80)
                Image(systemName: model.allGranted ? "checkmark" : "mic.fill")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(spacing: 8) {
                Text(model.allGranted ? "You're all set!" : "Almost there")
                    .font(.system(size: 23, weight: .bold))
                Text(model.allGranted
                     ? "Try it now: hold **Caps Lock** and press **R**, say a sentence, then press **R** again. Your text lands right where your cursor is."
                     : "You can finish granting permissions any time from the menu-bar popover or Settings — the app will light up as soon as you do.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 34)

            VStack(spacing: 8) {
                shortcutRow("R", "Record / stop", "mic.fill")
                shortcutRow("E", "Email reply", "envelope.fill")
                shortcutRow("C", "Clipboard history", "doc.on.clipboard.fill")
            }
            .padding(.horizontal, 32)

            Text("Add your API key and fine-tune everything in **Settings**.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            VStack(spacing: 3) {
                Text("Open source · MIT · built by Hendrik Kleinwächter")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Link("View the source on GitHub ↗", destination: Self.repoURL)
                    .font(.caption.weight(.medium))
            }
            .multilineTextAlignment(.center)
            .padding(.bottom, 4)
        }
        .padding(.top, 28)
    }

    static let repoURL = URL(string: "https://github.com/hendricius/aihelper")!

    // MARK: Footer / navigation

    private var footer: some View {
        VStack(spacing: 14) {
            // progress dots
            HStack(spacing: 7) {
                ForEach(0...Self.lastStep, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }

            HStack {
                if step > 0 {
                    Button("Back") { step -= 1 }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Skip") { onDone() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if step >= Self.lastStep { onDone() }
                    else { step += 1 }
                } label: {
                    Text(primaryLabel).frame(minWidth: 92)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(.thinMaterial)
    }

    private var primaryLabel: String {
        switch step {
        case 0: return "Get Started"
        case Self.lastStep: return model.allGranted ? "Start Using AIHelper" : "Finish"
        default: return "Continue"
        }
    }

    // MARK: Reusable bits

    private var appMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [violet, blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 78, height: 78)
                .shadow(color: violet.opacity(0.35), radius: 10, y: 4)
            Image(systemName: "mic.fill")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    private func stepHeading(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.tint)
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
    }

    private func featureRow(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func shortcutRow(_ key: String, _ label: String, _ icon: String) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 3) {
                miniCap("⇪")
                Text("+").font(.caption2).foregroundStyle(.secondary)
                miniCap(key)
            }
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 20)
            Text(label).font(.callout)
            Spacer()
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func permissionRow(granted: Bool, icon: String, title: String, why: String, grant: @escaping () -> Void) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(granted ? Color.green : .secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button("Grant", action: grant)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(granted ? Color.green.opacity(0.08) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(granted ? Color.green.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .animation(.easeInOut, value: granted)
    }

    private func keycap(_ symbol: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(symbol).font(.system(size: 19, weight: .semibold, design: .rounded))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minWidth: 96)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.1)))
    }

    private func miniCap(_ symbol: String) -> some View {
        Text(symbol)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .frame(minWidth: 22)
            .padding(.vertical, 3)
            .padding(.horizontal, 5)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
