import Foundation

/// The API backend used for audio transcription and chat-based text formatting.
///
/// Both providers speak the OpenAI-compatible REST shape (`/v1/audio/transcriptions`
/// and `/v1/chat/completions`), so the request-building code is shared — only the base
/// URL, API key, and model differ.
///
/// Keys are stored in `UserDefaults` to stay compatible with the `make load-env` workflow
/// (which writes them via `defaults write`). TODO(security): migrate API-key storage to the
/// Keychain and update `make load-env` accordingly before a wide public release.
enum APIProvider: String, CaseIterable, Identifiable {
    case openAI
    case aiCoordinator

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .aiCoordinator: return "AI Coordinator"
        case .openAI: return "OpenAI"
        }
    }

    /// UserDefaults key under which this provider's API key is stored.
    var apiKeyDefaultsKey: String {
        switch self {
        case .aiCoordinator: return "aicoordinator_api_key"
        case .openAI: return "openai_api_key"
        }
    }

    /// Where to obtain an API key (shown in Settings).
    var apiKeyURL: URL {
        switch self {
        case .aiCoordinator: return URL(string: "https://aicoordinator.spacebread.dev")!
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    var transcriptionURL: URL {
        switch self {
        case .aiCoordinator: return URL(string: "https://aicoordinator.spacebread.dev/v1/audio/transcriptions")!
        case .openAI: return URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        }
    }

    var chatCompletionsURL: URL {
        switch self {
        case .aiCoordinator: return URL(string: "https://aicoordinator.spacebread.dev/v1/chat/completions")!
        case .openAI: return URL(string: "https://api.openai.com/v1/chat/completions")!
        }
    }

    /// Model used for audio transcription.
    var transcriptionModel: String {
        switch self {
        case .aiCoordinator: return "whisper-1"
        case .openAI: return "whisper-1"
        }
    }

    /// Model used for chat-based text formatting.
    var chatModel: String {
        switch self {
        case .aiCoordinator: return "gpt-4o-mini"
        case .openAI: return "gpt-4o-mini"
        }
    }

    /// This provider's stored API key, or nil if empty/unset.
    var apiKey: String? {
        guard let key = UserDefaults.standard.string(forKey: apiKeyDefaultsKey), !key.isEmpty else {
            return nil
        }
        return key
    }

    // MARK: - Active provider selection

    /// UserDefaults key holding the raw value of the currently selected provider.
    static let activeProviderDefaultsKey = "active_api_provider"

    /// The currently selected provider (defaults to OpenAI).
    static var active: APIProvider {
        get {
            let raw = UserDefaults.standard.string(forKey: activeProviderDefaultsKey) ?? ""
            return APIProvider(rawValue: raw) ?? .openAI
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: activeProviderDefaultsKey)
        }
    }
}
