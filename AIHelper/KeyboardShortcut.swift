import AppKit
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "KeyboardShortcut")

/// Represents a keyboard shortcut configuration
struct ShortcutConfig: Hashable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let name: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
        hasher.combine(name)
    }

    static func == (lhs: ShortcutConfig, rhs: ShortcutConfig) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers && lhs.name == rhs.name
    }

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.command) { parts.append("⌘") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        parts.append(keyCodeToString(keyCode))
        return parts.joined()
    }

    private func keyCodeToString(_ code: UInt16) -> String {
        switch code {
        case 1: return "S"
        case 14: return "E"
        case 15: return "R"
        case 17: return "T"
        case 35: return "P"
        case 49: return "Space"
        case 46: return "M"
        case 9: return "V"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 8: return "C"
        case 53: return "Esc"
        default: return "?"
        }
    }

    static let recording = ShortcutConfig(
        keyCode: 15,  // R
        modifiers: [.control, .option, .command, .shift],
        name: "Toggle Recording"
    )

    static let promptLibrary = ShortcutConfig(
        keyCode: 35,  // P
        modifiers: [.control, .option, .command, .shift],
        name: "Prompt Library"
    )

    static let formatting = ShortcutConfig(
        keyCode: 17,  // T
        modifiers: [.control, .option, .command, .shift],
        name: "Format Text"
    )

    static let emailReply = ShortcutConfig(
        keyCode: 14,  // E
        modifiers: [.control, .option, .command, .shift],
        name: "Email Reply"
    )

    static let casualMessage = ShortcutConfig(
        keyCode: 17,  // T
        modifiers: [.control, .option, .command, .shift],
        name: "Message"
    )

    // Prompt shortcuts (1-5)
    static let prompt1 = ShortcutConfig(
        keyCode: 18,  // 1
        modifiers: [.control, .option, .command, .shift],
        name: "Activate Prompt 1"
    )

    static let prompt2 = ShortcutConfig(
        keyCode: 19,  // 2
        modifiers: [.control, .option, .command, .shift],
        name: "Activate Prompt 2"
    )

    static let prompt3 = ShortcutConfig(
        keyCode: 20,  // 3
        modifiers: [.control, .option, .command, .shift],
        name: "Activate Prompt 3"
    )

    static let prompt4 = ShortcutConfig(
        keyCode: 21,  // 4
        modifiers: [.control, .option, .command, .shift],
        name: "Activate Prompt 4"
    )

    static let prompt5 = ShortcutConfig(
        keyCode: 23,  // 5
        modifiers: [.control, .option, .command, .shift],
        name: "Activate Prompt 5"
    )

    static let cancelProcessing = ShortcutConfig(
        keyCode: 53,  // Escape
        modifiers: [],  // Just Escape key, no modifiers needed
        name: "Cancel Processing"
    )

    static let sendScreenshot = ShortcutConfig(
        keyCode: 1,  // S key
        modifiers: [.control, .option, .command, .shift],
        name: "Send Screenshot to VM"
    )

    static let clipboardHistory = ShortcutConfig(
        keyCode: 8,  // C
        modifiers: [.control, .option, .command, .shift],
        name: "Clipboard History"
    )
}

class GlobalKeyboardShortcut {
    static let shared = GlobalKeyboardShortcut()

    private var eventMonitor: Any?
    private var localMonitor: Any?
    private var shortcuts: [ShortcutConfig: () -> Void] = [:]
    private let queue = DispatchQueue(label: "com.aihelper.keyboard", qos: .userInteractive)

    deinit {
        unregister()
    }

    func register(shortcut: ShortcutConfig, callback: @escaping () -> Void) {
        queue.sync {
            shortcuts[shortcut] = callback
            ensureMonitorsActive()
        }
        logger.info("Registered shortcut: \(shortcut.name) (\(shortcut.displayString))")
    }

    func registerMultiple(_ registrations: [(ShortcutConfig, () -> Void)]) {
        queue.sync {
            for (shortcut, callback) in registrations {
                shortcuts[shortcut] = callback
                logger.debug("Registered: \(shortcut.name)")
            }
            ensureMonitorsActive()
        }
        logger.info("Registered \(registrations.count) shortcuts")
    }

    func unregister() {
        queue.sync {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
                logger.debug("Removed global event monitor")
            }
            if let monitor = localMonitor {
                NSEvent.removeMonitor(monitor)
                localMonitor = nil
                logger.debug("Removed local event monitor")
            }
            shortcuts.removeAll()
        }
        logger.info("All shortcuts unregistered")
    }

    func unregister(shortcut: ShortcutConfig) {
        queue.sync {
            shortcuts.removeValue(forKey: shortcut)
        }
        logger.debug("Unregistered shortcut: \(shortcut.name)")
    }

    // MARK: - Private Methods

    private func ensureMonitorsActive() {
        // Must be called within queue.sync
        guard eventMonitor == nil else { return }

        // Global monitor for when app is not active
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }

        // Local monitor for when app is active
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }

        logger.debug("Event monitors activated")
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let pressedModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Thread-safe access to shortcuts
        let matchedCallback: (() -> Void)? = queue.sync {
            for (shortcut, callback) in shortcuts {
                if event.keyCode == shortcut.keyCode && pressedModifiers == shortcut.modifiers {
                    logger.debug("Shortcut matched: \(shortcut.name)")
                    return callback
                }
            }
            return nil
        }

        // Execute callback on main thread
        if let callback = matchedCallback {
            DispatchQueue.main.async {
                callback()
            }
        }
    }
}
