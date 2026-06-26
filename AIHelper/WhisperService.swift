import Foundation
import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "WhisperService")

actor WhisperService {
    static let shared = WhisperService()

    private let session: URLSession

    init() {
        // Configure session with timeout
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120  // 120 seconds for request (increased for slow connections)
        config.timeoutIntervalForResource = 600  // 10 minutes for large audio files
        self.session = URLSession(configuration: config)
    }

    /// Progress callback type for upload progress
    typealias ProgressHandler = @Sendable (Double) -> Void

    /// Supported audio formats for Whisper API
    private let supportedFormats = ["mp3", "mp4", "mpeg", "mpga", "m4a", "wav", "webm", "ogg"]

    /// Transcribe audio to text with progress tracking
    /// - Parameters:
    ///   - audioURL: URL to the audio file
    ///   - promptHint: Optional text with names/terminology to guide transcription spelling
    ///   - onProgress: Optional callback for upload progress (0.0 to 1.0)
    func transcribe(audioURL: URL, promptHint: String? = nil, onProgress: ProgressHandler? = nil) async throws -> (text: String, apiLog: APICallLog) {
        logger.info("Starting transcription for: \(audioURL.lastPathComponent)")

        let provider = APIProvider.active
        guard let apiKey = provider.apiKey, !apiKey.isEmpty else {
            logger.error("API key not configured")
            throw WhisperError.missingAPIKey
        }

        // Validate audio file exists and is readable
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            logger.error("Audio file not found: \(audioURL.path)")
            throw WhisperError.audioFileNotFound
        }

        // Check if conversion is needed (e.g., .qta files)
        var urlToTranscribe = audioURL
        let fileExtension = audioURL.pathExtension.lowercased()
        var tempFileURL: URL?

        if !supportedFormats.contains(fileExtension) {
            logger.info("Converting \(fileExtension) to m4a for Whisper API compatibility")
            do {
                let convertedURL = try await convertAudioToM4A(sourceURL: audioURL)
                urlToTranscribe = convertedURL
                tempFileURL = convertedURL
            } catch {
                logger.error("Audio conversion failed: \(error.localizedDescription)")
                throw WhisperError.audioConversionFailed(error.localizedDescription)
            }
        }

        // Clean up temp file after transcription
        defer {
            if let tempURL = tempFileURL {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: urlToTranscribe)
            logger.debug("Loaded audio data: \(audioData.count) bytes")
        } catch {
            logger.error("Failed to read audio file: \(error.localizedDescription)")
            throw WhisperError.audioFileReadError(error.localizedDescription)
        }

        // Validate file size (Whisper API limit is 25MB)
        let maxSize = 25 * 1024 * 1024
        guard audioData.count <= maxSize else {
            logger.error("Audio file too large: \(audioData.count) bytes (max: \(maxSize))")
            throw WhisperError.audioFileTooLarge
        }

        let boundary = UUID().uuidString

        var request = URLRequest(url: provider.transcriptionURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Build multipart body safely
        let body = buildMultipartBody(boundary: boundary, audioData: audioData, model: provider.transcriptionModel, promptHint: promptHint)
        request.httpBody = body

        // Build request summary for logging
        var requestParts = ["model=\(provider.transcriptionModel)", "file=audio.m4a (\(audioData.count) bytes)", "response_format=json"]
        if let hint = promptHint, !hint.isEmpty {
            requestParts.append("prompt=\(hint)")
        }
        let requestSummary = requestParts.joined(separator: ", ")

        logger.debug("Sending request to Whisper API...")

        let requestStart = Date()
        let data: Data
        let response: URLResponse

        do {
            if let progressHandler = onProgress {
                // Use delegate-based upload for progress tracking
                let delegate = UploadProgressDelegate(onProgress: progressHandler)
                let delegateSession = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)
                defer { delegateSession.finishTasksAndInvalidate() }

                (data, response) = try await delegateSession.data(for: request)
            } else {
                (data, response) = try await session.data(for: request)
            }
        } catch let error as URLError {
            logger.error("Network error: \(error.localizedDescription)")
            throw WhisperError.networkError(describeURLError(error))
        } catch {
            logger.error("Request failed: \(error.localizedDescription)")
            throw WhisperError.networkError(error.localizedDescription)
        }

        let requestDurationMs = Int(Date().timeIntervalSince(requestStart) * 1000)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type")
            throw WhisperError.invalidResponse
        }

        let rawResponseBody = String(data: data, encoding: .utf8) ?? "(binary data)"

        logger.debug("Response status: \(httpResponse.statusCode)")

        // Handle specific HTTP errors
        switch httpResponse.statusCode {
        case 200:
            break // Success, continue processing
        case 401:
            logger.error("Authentication failed")
            throw WhisperError.invalidAPIKey
        case 429:
            logger.error("Rate limited")
            throw WhisperError.rateLimited
        case 500...599:
            logger.error("Server error: \(httpResponse.statusCode)")
            throw WhisperError.serverError(httpResponse.statusCode)
        default:
            let errorMessage = parseAPIError(from: data) ?? "HTTP \(httpResponse.statusCode)"
            logger.error("API error: \(errorMessage)")
            throw WhisperError.apiError(errorMessage)
        }

        // Parse successful response
        do {
            let result = try JSONDecoder().decode(WhisperResponse.self, from: data)
            logger.info("Transcription successful: \(result.text.prefix(50))...")

            let apiLog = APICallLog(
                endpoint: provider.transcriptionURL.absoluteString,
                statusCode: httpResponse.statusCode,
                durationMs: requestDurationMs,
                requestSummary: requestSummary,
                requestBody: nil,
                responseBody: rawResponseBody
            )

            return (text: result.text, apiLog: apiLog)
        } catch {
            logger.error("Failed to decode response: \(error.localizedDescription)")
            if let rawResponse = String(data: data, encoding: .utf8) {
                logger.debug("Raw response: \(rawResponse.prefix(500))")
            }
            throw WhisperError.decodingError(error.localizedDescription)
        }
    }

    // MARK: - Private Helpers

    /// Convert audio file to M4A format for Whisper API compatibility
    private func convertAudioToM4A(sourceURL: URL) async throws -> URL {
        let asset = AVAsset(url: sourceURL)

        // Create output URL in temp directory
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent(UUID().uuidString + ".m4a")

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "WhisperService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create export session"])
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a

        await exportSession.export()

        switch exportSession.status {
        case .completed:
            logger.info("Audio conversion completed: \(outputURL.lastPathComponent)")
            return outputURL
        case .failed:
            let error = exportSession.error?.localizedDescription ?? "Unknown error"
            throw NSError(domain: "WhisperService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Export failed: \(error)"])
        case .cancelled:
            throw NSError(domain: "WhisperService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Export was cancelled"])
        default:
            throw NSError(domain: "WhisperService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unexpected export status"])
        }
    }

    private func buildMultipartBody(boundary: String, audioData: Data, model: String, promptHint: String? = nil) -> Data {
        var body = Data()

        // Helper to safely append string data
        func appendString(_ string: String) {
            if let data = string.data(using: .utf8) {
                body.append(data)
            }
        }

        // Add model field
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        appendString("\(model)\r\n")

        // Add optional prompt hint for name/terminology spelling
        if let hint = promptHint, !hint.isEmpty {
            appendString("--\(boundary)\r\n")
            appendString("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
            appendString("\(hint)\r\n")
        }

        // Add audio file
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n")
        appendString("Content-Type: audio/m4a\r\n\r\n")
        body.append(audioData)
        appendString("\r\n")

        // Add response format
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        appendString("json\r\n")

        // End boundary
        appendString("--\(boundary)--\r\n")

        return body
    }

    private func parseAPIError(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return message
    }

    private func describeURLError(_ error: URLError) -> String {
        switch error.code {
        case .timedOut:
            return "Request timed out. Please try again."
        case .notConnectedToInternet:
            return "No internet connection."
        case .networkConnectionLost:
            return "Network connection was lost."
        case .cannotConnectToHost:
            return "Cannot connect to server."
        case .secureConnectionFailed:
            return "Secure connection failed."
        default:
            return error.localizedDescription
        }
    }

}

// MARK: - Response Model

struct WhisperResponse: Codable {
    let text: String
}

// MARK: - Error Types

enum WhisperError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case invalidResponse
    case audioFileNotFound
    case audioFileReadError(String)
    case audioFileTooLarge
    case audioConversionFailed(String)
    case networkError(String)
    case rateLimited
    case serverError(Int)
    case decodingError(String)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "AI Coordinator API key not set. Please add it in Settings."
        case .invalidAPIKey:
            return "Invalid AI Coordinator API key. Please check your key in Settings."
        case .invalidResponse:
            return "Invalid response from server."
        case .audioFileNotFound:
            return "Audio file not found."
        case .audioFileReadError(let message):
            return "Failed to read audio file: \(message)"
        case .audioFileTooLarge:
            return "Audio file is too large. Maximum size is 25MB."
        case .audioConversionFailed(let message):
            return "Failed to convert audio format: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .rateLimited:
            return "Rate limited. Please wait a moment and try again."
        case .serverError(let code):
            return "Server error (\(code)). Please try again later."
        case .decodingError(let message):
            return "Failed to process response: \(message)"
        case .apiError(let message):
            return "API Error: \(message)"
        }
    }

    /// Returns true if this error is due to a network issue that can be retried
    var isRetryable: Bool {
        switch self {
        case .networkError, .serverError, .rateLimited:
            return true
        default:
            return false
        }
    }
}

// MARK: - Upload Progress Delegate

/// Delegate for tracking upload progress
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        onProgress(progress)
    }
}
