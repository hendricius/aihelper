import Foundation
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "TranscriptionServiceRouter")

/// Routes transcription requests to the cloud transcription service
actor TranscriptionServiceRouter {
    static let shared = TranscriptionServiceRouter()

    /// Maximum time to wait for cloud transcription before treating it as a failure
    private let cloudTranscriptionTimeout: Duration = .seconds(15)

    private init() {}

    /// Progress callback type for upload progress
    typealias ProgressHandler = @Sendable (Double) -> Void

    /// Transcribe audio file using the cloud service
    /// - Parameters:
    ///   - audioURL: URL to the audio file
    ///   - promptHint: Optional text with names/terminology to guide transcription spelling
    ///   - onProgress: Optional callback for upload progress
    @MainActor
    func transcribe(audioURL: URL, promptHint: String? = nil, onProgress: ProgressHandler? = nil) async throws -> (text: String, apiLog: APICallLog) {
        logger.info("Transcribing with cloud service (AI Coordinator)")
        return try await transcribeWithCloud(audioURL: audioURL, promptHint: promptHint, onProgress: onProgress)
    }

    /// Transcribe using the cloud (AI Coordinator) service with a timeout to detect slow/flaky API
    private func transcribeWithCloud(audioURL: URL, promptHint: String?, onProgress: ProgressHandler?) async throws -> (text: String, apiLog: APICallLog) {
        logger.debug("Using cloud transcription (AI Coordinator) with \(self.cloudTranscriptionTimeout) timeout")

        return try await withThrowingTaskGroup(of: (text: String, apiLog: APICallLog).self) { group in
            group.addTask {
                try await WhisperService.shared.transcribe(
                    audioURL: audioURL,
                    promptHint: promptHint,
                    onProgress: onProgress
                )
            }

            group.addTask {
                try await Task.sleep(for: self.cloudTranscriptionTimeout)
                throw WhisperError.networkError("Transcription timed out after 15 seconds. The server may be slow or unreachable.")
            }

            // Return the result of whichever task finishes first
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
