import Foundation
import Speech
import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "StopWordDetector")

/// Real-time speech recognition for stop word detection
@MainActor
class StopWordDetector: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var lastPartialResult: String = ""

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Thread-safe reference for buffer appending from audio tap callback
    nonisolated(unsafe) private var bufferRequest: SFSpeechAudioBufferRecognitionRequest?

    /// Debounce work item for stop word confirmation
    private var stopWordConfirmationTask: Task<Void, Never>?
    /// The transcription that triggered pending stop word detection
    private var pendingStopWordTranscription: String?
    /// Delay before confirming stop word (allows partial results to complete)
    private let stopWordDebounceDelay: UInt64 = 700_000_000 // 700ms in nanoseconds

    var onStopWordDetected: (() -> Void)?

    init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
        logger.info("StopWordDetector initialized with locale: \(Locale.current.identifier)")
    }

    // MARK: - Authorization

    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    // MARK: - Detection Control

    /// Start listening for stop words. Call this when recording begins.
    func startListening() {
        guard StopWordDefaults.isEnabled else {
            logger.debug("Stop word detection is disabled")
            return
        }

        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            logger.warning("Speech recognizer not available")
            return
        }

        // Cancel any existing recognition task
        stopListening()

        let request = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest = request
        bufferRequest = request

        // Configure for real-time results
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false

        // Add task hints if available
        if #available(macOS 13.0, *) {
            request.addsPunctuation = false
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognitionResult(result: result, error: error)
            }
        }

        isListening = true
        logger.info("Started listening for stop word: '\(StopWordDefaults.stopWord)'")
    }

    /// Stop listening for stop words.
    func stopListening() {
        cancelPendingStopWordConfirmation()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        bufferRequest = nil
        isListening = false
        lastPartialResult = ""
        logger.debug("Stopped listening for stop word")
    }

    /// Append audio buffer from AVAudioEngine tap.
    /// This must be called from the audio tap callback.
    nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        bufferRequest?.append(buffer)
    }

    // MARK: - Private Methods

    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?) {
        if let error = error {
            // Ignore cancellation errors - these are expected when we stop listening
            let nsError = error as NSError
            if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                // Recognition was cancelled, this is normal
                return
            }
            logger.warning("Speech recognition error: \(error.localizedDescription)")
            return
        }

        guard let result = result else { return }

        let transcription = result.bestTranscription.formattedString
        lastPartialResult = transcription

        // Check if the stop word is at the end
        if checkForStopWord(in: transcription) {
            if result.isFinal {
                // Final result ends with stop word - trigger immediately
                logger.info("Stop word detected in final result: '\(transcription)'")
                cancelPendingStopWordConfirmation()
                onStopWordDetected?()
            } else {
                // Partial result - use debouncing to avoid false positives
                // (e.g., "over" being recognized before "overview" completes)
                scheduleStopWordConfirmation(transcription: transcription)
            }
        } else {
            // Transcription changed and no longer ends with stop word - cancel pending confirmation
            cancelPendingStopWordConfirmation()
        }
    }

    /// Schedule a delayed confirmation of stop word detection.
    /// This allows partial speech recognition results to complete before triggering.
    private func scheduleStopWordConfirmation(transcription: String) {
        // If we already have a pending confirmation for the same transcription, keep waiting
        if pendingStopWordTranscription == transcription {
            return
        }

        // Cancel any existing pending confirmation
        cancelPendingStopWordConfirmation()

        pendingStopWordTranscription = transcription
        logger.debug("Scheduling stop word confirmation for: '\(transcription)'")

        stopWordConfirmationTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.stopWordDebounceDelay ?? 400_000_000)

                guard let self = self else { return }

                // Verify the transcription hasn't changed since we scheduled
                if self.pendingStopWordTranscription == transcription && self.checkForStopWord(in: self.lastPartialResult) {
                    logger.info("Stop word confirmed in: '\(transcription)'")
                    self.pendingStopWordTranscription = nil
                    self.onStopWordDetected?()
                }
            } catch {
                // Task was cancelled, which is expected
            }
        }
    }

    /// Cancel any pending stop word confirmation
    private func cancelPendingStopWordConfirmation() {
        if pendingStopWordTranscription != nil {
            logger.debug("Cancelling pending stop word confirmation")
        }
        stopWordConfirmationTask?.cancel()
        stopWordConfirmationTask = nil
        pendingStopWordTranscription = nil
    }

    /// Check if the transcription ends with the stop word
    private func checkForStopWord(in text: String) -> Bool {
        let stopWord = StopWordDefaults.stopWord.lowercased()
        let normalizedText = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove trailing punctuation for comparison
        let textWithoutPunctuation = normalizedText.trimmingCharacters(in: .punctuationCharacters)

        // Check if it ends with the stop word (as a whole word)
        let words = textWithoutPunctuation.components(separatedBy: .whitespaces)
        if let lastWord = words.last {
            return lastWord == stopWord
        }

        return false
    }
}
