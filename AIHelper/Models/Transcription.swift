import Foundation

/// The mode used when creating a transcription
enum TranscriptionMode: String, Codable {
    case transcription = "transcription"
    case email = "email"
    case formatting = "formatting"
    case casualMessage = "casualMessage"

    var displayName: String {
        switch self {
        case .transcription: return "Transcription"
        case .email: return "Email"
        case .formatting: return "Formatted"
        case .casualMessage: return "Message"
        }
    }
}

/// Captures request/response details from an API call for debugging
struct APICallLog: Codable, Equatable {
    let endpoint: String
    let statusCode: Int
    let durationMs: Int
    let requestSummary: String   // human-readable summary of what was sent
    let requestBody: String?     // full JSON request body (for chat completions)
    let responseBody: String     // raw JSON response
}

struct Transcription: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let date: Date

    // Debugging metadata
    let mode: TranscriptionMode
    let formattingApplied: Bool
    let promptUsed: String?
    let originalContext: String?  // For email mode: the original email text
    let rawTranscription: String?  // The original transcription before formatting

    // Audio & performance metadata
    let audioFileName: String?          // e.g. "uuid.m4a" - relative to audio dir
    let audioDurationSeconds: Double?   // recording length
    let audioFileSizeBytes: Int?        // .m4a file size
    let transcriptionDurationMs: Int?   // wall-clock time for transcribe() call
    let formattingDurationMs: Int?      // wall-clock time for formatting call
    let transcriptionEngine: String?    // "cloud"

    // API call logs for debugging
    let transcriptionAPILog: APICallLog?
    let formattingAPILog: APICallLog?

    init(
        id: UUID = UUID(),
        text: String,
        date: Date,
        mode: TranscriptionMode = .transcription,
        formattingApplied: Bool = false,
        promptUsed: String? = nil,
        originalContext: String? = nil,
        rawTranscription: String? = nil,
        audioFileName: String? = nil,
        audioDurationSeconds: Double? = nil,
        audioFileSizeBytes: Int? = nil,
        transcriptionDurationMs: Int? = nil,
        formattingDurationMs: Int? = nil,
        transcriptionEngine: String? = nil,
        transcriptionAPILog: APICallLog? = nil,
        formattingAPILog: APICallLog? = nil
    ) {
        self.id = id
        self.text = text
        self.date = date
        self.mode = mode
        self.formattingApplied = formattingApplied
        self.promptUsed = promptUsed
        self.originalContext = originalContext
        self.rawTranscription = rawTranscription
        self.audioFileName = audioFileName
        self.audioDurationSeconds = audioDurationSeconds
        self.audioFileSizeBytes = audioFileSizeBytes
        self.transcriptionDurationMs = transcriptionDurationMs
        self.formattingDurationMs = formattingDurationMs
        self.transcriptionEngine = transcriptionEngine
        self.transcriptionAPILog = transcriptionAPILog
        self.formattingAPILog = formattingAPILog
    }

    /// Generates a debug summary that can be copied to clipboard for troubleshooting
    func debugSummary() -> String {
        var parts: [String] = []

        parts.append("=== TRANSCRIPTION DEBUG INFO ===")
        parts.append("Date: \(date)")
        parts.append("Mode: \(mode.displayName)")
        parts.append("Formatting Applied: \(formattingApplied)")
        if let prompt = promptUsed {
            parts.append("Prompt Used: \(prompt)")
        }
        if let duration = audioDurationSeconds {
            parts.append("Recording Duration: \(String(format: "%.1f", duration))s")
        }
        if let size = audioFileSizeBytes {
            parts.append("Audio Size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
        }
        if let ms = transcriptionDurationMs {
            parts.append("Transcription Time: \(ms)ms")
        }
        if let ms = formattingDurationMs {
            parts.append("Formatting Time: \(ms)ms")
        }
        if let engine = transcriptionEngine {
            parts.append("Engine: \(engine)")
        }

        parts.append("")
        parts.append("=== RAW TRANSCRIPTION ===")
        parts.append(rawTranscription ?? "(not available)")

        if let context = originalContext {
            parts.append("")
            parts.append("=== ORIGINAL EMAIL ===")
            parts.append(context)
        }

        parts.append("")
        parts.append("=== FORMATTED OUTPUT ===")
        parts.append(text)

        if let log = transcriptionAPILog {
            parts.append("")
            parts.append("=== TRANSCRIPTION API CALL ===")
            parts.append("Endpoint: \(log.endpoint)")
            parts.append("Status: \(log.statusCode)")
            parts.append("Duration: \(log.durationMs)ms")
            parts.append("Request: \(log.requestSummary)")
            parts.append("Response: \(log.responseBody)")
        }

        if let log = formattingAPILog {
            parts.append("")
            parts.append("=== FORMATTING API CALL ===")
            parts.append("Endpoint: \(log.endpoint)")
            parts.append("Status: \(log.statusCode)")
            parts.append("Duration: \(log.durationMs)ms")
            parts.append("Request: \(log.requestSummary)")
            if let body = log.requestBody {
                parts.append("Request Body: \(body)")
            }
            parts.append("Response: \(log.responseBody)")
        }

        return parts.joined(separator: "\n")
    }
}
