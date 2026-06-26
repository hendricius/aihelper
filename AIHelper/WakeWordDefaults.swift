import Foundation

/// Settings for wake word detection (always-on listening to start recording)
enum WakeWordDefaults {

    // MARK: - UserDefaults Keys

    static let enabledKey = "wake_word_enabled"
    static let wordKey = "wake_word"
    static let useFormattingModeKey = "wake_word_use_formatting"

    // MARK: - Default Values

    static let defaultWakeWord = "dictate"
    static let defaultEnabled = false
    static let defaultUseFormattingMode = false

    // MARK: - Settings Accessors

    /// Whether wake word detection is enabled
    static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    /// The wake word to detect (case-insensitive)
    static var wakeWord: String {
        get {
            let word = UserDefaults.standard.string(forKey: wordKey)
            return (word?.isEmpty == false) ? word! : defaultWakeWord
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: wordKey)
        }
    }

    /// Whether to use formatting mode when wake word triggers recording
    static var useFormattingMode: Bool {
        get {
            UserDefaults.standard.object(forKey: useFormattingModeKey) as? Bool ?? defaultUseFormattingMode
        }
        set {
            UserDefaults.standard.set(newValue, forKey: useFormattingModeKey)
        }
    }

    // MARK: - Reset

    /// Reset all wake word settings to defaults
    static func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: wordKey)
        UserDefaults.standard.removeObject(forKey: useFormattingModeKey)
    }
}
