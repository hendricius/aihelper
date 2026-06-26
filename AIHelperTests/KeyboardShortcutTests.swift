import XCTest
@testable import AIHelper

final class KeyboardShortcutTests: XCTestCase {

    // MARK: - ShortcutConfig Tests

    func testRecordingShortcutConfig() {
        let config = ShortcutConfig.recording

        XCTAssertEqual(config.keyCode, 15, "R key should have keyCode 15")
        XCTAssertTrue(config.modifiers.contains(.control))
        XCTAssertTrue(config.modifiers.contains(.option))
        XCTAssertTrue(config.modifiers.contains(.command))
        XCTAssertTrue(config.modifiers.contains(.shift))
        XCTAssertEqual(config.name, "Toggle Recording")
    }

    func testPromptLibraryShortcutConfig() {
        let config = ShortcutConfig.promptLibrary

        XCTAssertEqual(config.keyCode, 35, "P key should have keyCode 35")
        XCTAssertTrue(config.modifiers.contains(.control))
        XCTAssertTrue(config.modifiers.contains(.option))
        XCTAssertTrue(config.modifiers.contains(.command))
        XCTAssertTrue(config.modifiers.contains(.shift))
        XCTAssertEqual(config.name, "Prompt Library")
    }

    func testFormattingShortcutConfig() {
        let config = ShortcutConfig.formatting

        XCTAssertEqual(config.keyCode, 17, "T key should have keyCode 17")
        XCTAssertTrue(config.modifiers.contains(.control))
        XCTAssertTrue(config.modifiers.contains(.option))
        XCTAssertTrue(config.modifiers.contains(.command))
        XCTAssertTrue(config.modifiers.contains(.shift))
        XCTAssertEqual(config.name, "Format Text")
    }

    func testShortcutDisplayString() {
        let config = ShortcutConfig.recording
        let display = config.displayString

        XCTAssertTrue(display.contains("⌃"), "Should contain control symbol")
        XCTAssertTrue(display.contains("⌥"), "Should contain option symbol")
        XCTAssertTrue(display.contains("⌘"), "Should contain command symbol")
        XCTAssertTrue(display.contains("⇧"), "Should contain shift symbol")
        XCTAssertTrue(display.contains("R"), "Should contain key letter")
    }

    func testPromptLibraryDisplayString() {
        let config = ShortcutConfig.promptLibrary
        let display = config.displayString

        XCTAssertTrue(display.contains("P"), "Should contain key letter P")
    }

    func testFormattingDisplayString() {
        let config = ShortcutConfig.formatting
        let display = config.displayString

        XCTAssertTrue(display.contains("⌃"), "Should contain control symbol")
        XCTAssertTrue(display.contains("⌥"), "Should contain option symbol")
        XCTAssertTrue(display.contains("⌘"), "Should contain command symbol")
        XCTAssertTrue(display.contains("⇧"), "Should contain shift symbol")
        XCTAssertTrue(display.contains("T"), "Should contain key letter T")
    }

    func testShortcutConfigEquality() {
        let config1 = ShortcutConfig.recording
        let config2 = ShortcutConfig(
            keyCode: 15,
            modifiers: [.control, .option, .command, .shift],
            name: "Toggle Recording"
        )

        XCTAssertEqual(config1, config2, "Identical configs should be equal")
    }

    func testShortcutConfigInequality() {
        let config1 = ShortcutConfig.recording
        let config2 = ShortcutConfig.promptLibrary

        XCTAssertNotEqual(config1, config2, "Different configs should not be equal")
    }

    func testShortcutConfigHashable() {
        var set = Set<ShortcutConfig>()

        set.insert(ShortcutConfig.recording)
        set.insert(ShortcutConfig.promptLibrary)
        set.insert(ShortcutConfig.formatting)
        set.insert(ShortcutConfig.recording) // Duplicate

        XCTAssertEqual(set.count, 3, "Set should contain only unique configs")
    }

    func testCustomShortcutConfig() {
        let custom = ShortcutConfig(
            keyCode: 49,  // Space
            modifiers: [.command],
            name: "Custom Action"
        )

        XCTAssertEqual(custom.keyCode, 49)
        XCTAssertEqual(custom.name, "Custom Action")
        XCTAssertTrue(custom.displayString.contains("Space"))
        XCTAssertTrue(custom.displayString.contains("⌘"))
    }

    func testUnknownKeyCodeDisplayString() {
        let config = ShortcutConfig(
            keyCode: 999,  // Unknown key
            modifiers: [.command],
            name: "Unknown"
        )

        XCTAssertTrue(config.displayString.contains("?"), "Unknown key should show ?")
    }

    // MARK: - GlobalKeyboardShortcut Tests

    func testSharedInstanceExists() {
        let instance = GlobalKeyboardShortcut.shared
        XCTAssertNotNil(instance)
    }

    func testSharedInstanceIsSingleton() {
        let instance1 = GlobalKeyboardShortcut.shared
        let instance2 = GlobalKeyboardShortcut.shared
        XCTAssertTrue(instance1 === instance2, "Should be the same instance")
    }

    func testRegisterAndUnregister() {
        let shortcut = GlobalKeyboardShortcut.shared
        var callbackCalled = false

        shortcut.register(shortcut: .recording) {
            callbackCalled = true
        }

        // Unregister specific shortcut
        shortcut.unregister(shortcut: .recording)

        // Should not crash when unregistering again
        shortcut.unregister(shortcut: .recording)
    }

    func testRegisterMultiple() {
        let shortcut = GlobalKeyboardShortcut.shared
        var recordingCalled = false
        var promptCalled = false
        var formattingCalled = false

        shortcut.registerMultiple([
            (.recording, { recordingCalled = true }),
            (.promptLibrary, { promptCalled = true }),
            (.formatting, { formattingCalled = true })
        ])

        // Clean up
        shortcut.unregister()
    }

    func testUnregisterAll() {
        let shortcut = GlobalKeyboardShortcut.shared

        shortcut.registerMultiple([
            (.recording, {}),
            (.promptLibrary, {}),
            (.formatting, {})
        ])

        // Should not crash
        shortcut.unregister()

        // Should be safe to call multiple times
        shortcut.unregister()
        shortcut.unregister()
    }
}
