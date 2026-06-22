import Foundation

/// Represents a failed API request that can be retried later
struct FailedRequest: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let errorMessage: String
    let requestType: RequestType

    /// The audio file data for transcription requests
    let audioData: Data?

    /// The text for formatting requests
    let text: String?

    /// Whether formatting was requested for transcription
    let formattingEnabled: Bool

    enum RequestType: String, Codable {
        case transcription
        case formatting
    }

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        errorMessage: String,
        requestType: RequestType,
        audioData: Data? = nil,
        text: String? = nil,
        formattingEnabled: Bool = false
    ) {
        self.id = id
        self.date = date
        self.errorMessage = errorMessage
        self.requestType = requestType
        self.audioData = audioData
        self.text = text
        self.formattingEnabled = formattingEnabled
    }

    /// Creates a failed transcription request from audio data
    static func transcription(
        audioData: Data,
        errorMessage: String,
        formattingEnabled: Bool = false
    ) -> FailedRequest {
        FailedRequest(
            errorMessage: errorMessage,
            requestType: .transcription,
            audioData: audioData,
            formattingEnabled: formattingEnabled
        )
    }

    /// Creates a failed formatting request from text
    static func formatting(text: String, errorMessage: String) -> FailedRequest {
        FailedRequest(
            errorMessage: errorMessage,
            requestType: .formatting,
            text: text
        )
    }
}
