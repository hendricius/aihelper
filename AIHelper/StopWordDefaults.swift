import Foundation

/// Settings for stop word detection during recording
enum StopWordDefaults {

    // MARK: - UserDefaults Keys

    static let enabledKey = "stop_word_enabled"
    static let wordKey = "stop_word"
    static let autoPasteKey = "stop_word_auto_paste"

    // MARK: - Default Values

    static let defaultStopWord = "over"
    static let defaultEnabled = false
    static let defaultAutoPaste = true

    // MARK: - Settings Accessors

    /// Whether stop word detection is enabled
    static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    /// The stop word to detect (case-insensitive)
    static var stopWord: String {
        get {
            let word = UserDefaults.standard.string(forKey: wordKey)
            return (word?.isEmpty == false) ? word! : defaultStopWord
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: wordKey)
        }
    }

    /// Whether to automatically paste and press Return when stop word is detected
    static var autoPasteEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: autoPasteKey) as? Bool ?? defaultAutoPaste
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoPasteKey)
        }
    }

    // MARK: - Reset

    /// Reset all stop word settings to defaults
    static func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: wordKey)
        UserDefaults.standard.removeObject(forKey: autoPasteKey)
    }
}
