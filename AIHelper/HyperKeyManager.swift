import AppKit
import ApplicationServices
import IOKit
import IOKit.hidsystem
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "HyperKey")

/// Lifecycle/permission diagnostics via the unified log (Console.app / `log show`).
/// Never logs individual keystrokes.
private func hyperLog(_ message: String) {
    logger.info("\(message, privacy: .public)")
}

/// Force the physical Caps Lock LED/state OFF, so remapping it can never leave it stuck "on".
private func forceCapsLockOff() {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
    guard service != 0 else { return }
    defer { IOObjectRelease(service) }
    var connect: io_connect_t = 0
    guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return }
    defer { IOServiceClose(connect) }
    IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), false)
}

/// Turns Caps Lock into a "hyper key" (⌃⌥⌘⇧), so e.g. **Caps Lock + R** triggers the
/// ⌃⌥⌘⇧R recording shortcut — no external Hyperkey app needed.
///
/// Technique (the same one Karabiner/Hyperkey use):
///  1. A `CGEventTap` (needs Accessibility + Input Monitoring) is installed first.
///  2. Only if that succeeds, `hidutil` remaps Caps Lock (HID `0x700000039`) to **F18**
///     (`0x70000006D`) so it stops toggling. While F18 is held, the tap adds the four
///     hyper modifiers to every keypress and swallows F18 itself.
///
/// Crucially, we never remap Caps Lock unless the tap is live — otherwise a missing
/// permission would leave Caps Lock doing nothing. We also force Caps Lock off before
/// remapping so it can't get stuck in the "on" state.
final class HyperKeyManager {
    static let shared = HyperKeyManager()

    static let enabledKey = "hyperkey_enabled"

    private let hyperKeyCode: Int64 = 79  // F18
    private let hyperFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hyperDown = false

    private var permissionPollTimer: Timer?
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var pollAttempts = 0

    private init() {}

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// True when both permissions the event tap needs are currently granted.
    var hasTapPermissions: Bool {
        AXIsProcessTrusted() && CGPreflightListenEventAccess()
    }

    /// True when the hyper key is wanted (enabled) but not actually armed yet — i.e. the
    /// tap couldn't be installed, almost always because permissions are still missing.
    var isWaitingForPermissions: Bool {
        isEnabled && eventTap == nil
    }

    // MARK: - Lifecycle

    func startIfEnabled() {
        hyperLog("startIfEnabled() isEnabled=\(isEnabled) hasTapPermissions=\(hasTapPermissions)")
        guard isEnabled else { return }
        if hasTapPermissions {
            enable()  // permissions already granted — arm without prompting
        } else {
            // Fresh install: Accessibility / Input Monitoring usually aren't granted yet.
            // Don't fire a system prompt on launch (that's the welcome screen's job) — just
            // watch quietly and arm automatically once the user grants, so they never have
            // to toggle the hyper key off/on or relaunch.
            beginPermissionWatch()
        }
    }

    /// Explicit user request to turn the hyper key on (welcome screen, Settings toggle, or
    /// the popover's Fix button). Prompts for the permissions it needs, then arms now or as
    /// soon as they're granted.
    @discardableResult
    func enableRequestingPermissions() -> Bool {
        let armed = enable()
        if !armed { beginPermissionWatch() }
        return armed
    }

    // MARK: - Permission auto-arm

    /// Arm the hyper key if it's wanted, not yet armed, and permissions are now present.
    /// Returns true if it is (or became) armed. Safe to call repeatedly.
    @discardableResult
    func armIfReady() -> Bool {
        guard isEnabled else { return false }
        if eventTap != nil { return true }
        guard hasTapPermissions else { return false }
        let armed = enable()
        if armed { endPermissionWatch() }
        return armed
    }

    private func beginPermissionWatch() {
        // 1. Re-arm when the user returns to the app after granting in System Settings.
        if didBecomeActiveObserver == nil {
            didBecomeActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.armIfReady() }
        }
        // 2. Poll briefly to also catch the inline permission prompt being granted without
        //    leaving the app. didBecomeActive stays as a long-term backstop.
        permissionPollTimer?.invalidate()
        pollAttempts = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.pollAttempts += 1
            if self.armIfReady() || !self.isEnabled || self.pollAttempts > 80 {
                timer.invalidate()
                if self.permissionPollTimer === timer { self.permissionPollTimer = nil }
            }
        }
        permissionPollTimer = timer
        hyperLog("Waiting for Accessibility + Input Monitoring — will arm the hyper key automatically once granted")
    }

    private func endPermissionWatch() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    /// Enable the hyper key. Returns false if the event tap couldn't be created (missing
    /// Accessibility / Input Monitoring permission). When it returns false, Caps Lock is
    /// left completely untouched.
    @discardableResult
    func enable() -> Bool {
        let ax = AXIsProcessTrusted()
        let inputMon = CGPreflightListenEventAccess()
        hyperLog("enable() called. AXIsProcessTrusted=\(ax) InputMonitoring=\(inputMon)")

        // Prompt for the two permissions the tap needs (adds AIHelper to both lists).
        if !ax {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            hyperLog("AXIsProcessTrustedWithOptions(prompt) -> \(AXIsProcessTrustedWithOptions(opts))")
        }
        if !inputMon {
            hyperLog("CGRequestListenEventAccess() -> \(CGRequestListenEventAccess())")
        }

        // Tap FIRST. Only remap Caps Lock if the tap is actually live.
        guard installTap() else {
            hyperLog("Tap not installed — leaving Caps Lock untouched. Grant Accessibility + Input Monitoring, then relaunch.")
            return false
        }

        forceCapsLockOff()          // never leave Caps Lock stuck "on"
        remapCapsLock(toF18: true)
        hyperLog("Hyper key fully active (tap + remap)")
        return true
    }

    /// Disable the hyper key and restore normal Caps Lock behavior.
    func disable() {
        hyperLog("disable() called")
        endPermissionWatch()
        removeTap()
        remapCapsLock(toF18: false)
        forceCapsLockOff()
        hyperDown = false
    }

    /// Restore the OS-level Caps Lock mapping. Call on app quit.
    func resetMapping() {
        hyperLog("resetMapping() called")
        removeTap()
        remapCapsLock(toF18: false)
        forceCapsLockOff()
    }

    // MARK: - hidutil remap

    private func remapCapsLock(toF18 on: Bool) {
        let mapping = on
            ? #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}]}"#
            : #"{"UserKeyMapping":[]}"#

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", mapping]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            hyperLog("hidutil remap toF18=\(on) exit=\(process.terminationStatus)")
        } catch {
            hyperLog("hidutil FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - Event tap

    @discardableResult
    private func installTap() -> Bool {
        guard eventTap == nil else { return true }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: hyperKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            hyperLog("CGEvent.tapCreate returned nil (permission missing)")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        hyperLog("Event tap installed and enabled")
        return true
    }

    private func removeTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
            hyperLog("Event tap removed")
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Event handling (called from the C callback, on the main run loop)

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            hyperLog("tap disabled (\(type.rawValue)) — re-enabling")
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if keyCode == hyperKeyCode {
            if type == .keyDown { hyperDown = true }
            else if type == .keyUp { hyperDown = false }
            return nil
        }

        if hyperDown && (type == .keyDown || type == .keyUp) {
            event.flags.insert(hyperFlags)
        }
        return Unmanaged.passUnretained(event)
    }
}

/// C trampoline for the event tap.
private func hyperKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<HyperKeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handle(type: type, event: event)
}
