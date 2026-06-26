import Foundation
import Speech
import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "WakeWordDetector")

/// Always-on wake word detection to trigger voice recording
/// Runs its own audio engine and continuously listens for the wake word
@MainActor
class WakeWordDetector: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var lastHeardText: String = ""

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?

    /// Track when we detected the wake word to prevent immediate re-triggering
    private var lastWakeWordTime: Date = .distantPast
    private let wakeWordCooldown: TimeInterval = 3.0

    /// Timer to restart recognition sessions (SFSpeechRecognizer has a ~1 minute limit)
    private var sessionRestartTimer: Timer?
    private let sessionDuration: TimeInterval = 50.0 // Restart before the 60s limit

    /// Callback when wake word is detected
    var onWakeWordDetected: (() -> Void)?

    init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
        logger.info("WakeWordDetector initialized with locale: \(Locale.current.identifier)")
    }

    deinit {
        sessionRestartTimer?.invalidate()
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

    /// Track if we've already warned about permissions to avoid spam
    private var hasWarnedAboutPermissions = false

    /// Start listening for wake word. Call this when the app launches.
    func startListening() {
        guard WakeWordDefaults.isEnabled else {
            logger.debug("Wake word detection is disabled")
            return
        }

        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            logger.warning("Speech recognizer not available")
            return
        }

        // Check authorization
        let status = Self.authorizationStatus
        guard status == .authorized else {
            if status == .notDetermined {
                Task {
                    let newStatus = await Self.requestAuthorization()
                    if newStatus == .authorized {
                        self.hasWarnedAboutPermissions = false
                        await self.startListening()
                    } else {
                        logger.warning("Speech recognition authorization denied: \(newStatus.rawValue)")
                    }
                }
            } else if !hasWarnedAboutPermissions {
                logger.warning("Speech recognition not authorized: \(status.rawValue). Wake word detection disabled.")
                hasWarnedAboutPermissions = true
            }
            return
        }

        // Stop any existing session first
        stopListening()

        startRecognitionSession()
    }

    /// Stop listening for wake word.
    func stopListening() {
        sessionRestartTimer?.invalidate()
        sessionRestartTimer = nil

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil

        isListening = false
        lastHeardText = ""
        logger.debug("Stopped listening for wake word")
    }

    /// Temporarily pause listening (e.g., when recording starts)
    func pauseListening() {
        guard isListening else { return }
        logger.info("Pausing wake word detection")
        stopListening()
    }

    /// Resume listening after pause
    func resumeListening() {
        guard WakeWordDefaults.isEnabled else { return }
        guard !isListening else { return }
        logger.info("Resuming wake word detection")

        // Add a small delay to avoid picking up the end of the user's transcription
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
            await self.startListening()
        }
    }

    // MARK: - Private Methods

    private func startRecognitionSession() {
        logger.info("Starting wake word recognition session...")

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Get the native format of the input node
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
            logger.error("Invalid audio format from input node")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest = request

        // Configure for real-time results with low latency
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true // Use on-device for privacy and speed

        if #available(macOS 13.0, *) {
            request.addsPunctuation = false
        }

        // Install audio tap
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        // Start the audio engine
        do {
            try engine.start()
            audioEngine = engine
        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
            return
        }

        // Start recognition task
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognitionResult(result: result, error: error)
            }
        }

        isListening = true
        logger.info("Started listening for wake word: '\(WakeWordDefaults.wakeWord)'")

        // Set up timer to restart session before it times out
        scheduleSessionRestart()
    }

    private func scheduleSessionRestart() {
        sessionRestartTimer?.invalidate()
        sessionRestartTimer = Timer.scheduledTimer(withTimeInterval: sessionDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.restartSession()
            }
        }
    }

    private func restartSession() {
        guard isListening else { return }
        logger.debug("Restarting recognition session (session timeout prevention)")

        // Stop current session
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil

        // Start new session
        startRecognitionSession()
    }

    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?) {
        if let error = error {
            let nsError = error as NSError

            // Ignore cancellation errors - these are expected when we restart sessions
            if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                return
            }

            // Handle session timeout by restarting
            if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 209 {
                logger.debug("Recognition session ended, restarting...")
                restartSession()
                return
            }

            logger.warning("Speech recognition error: \(error.localizedDescription)")

            // Don't restart on permission errors (code 1110)
            if nsError.code == 1110 {
                logger.error("Speech recognition permission error - stopping wake word detection")
                stopListening()
                return
            }

            // Try to restart on other recoverable errors (but limit retries)
            if isListening {
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
                    await self.restartSession()
                }
            }
            return
        }

        guard let result = result else { return }

        let transcription = result.bestTranscription.formattedString
        lastHeardText = transcription

        // Check for wake word at the start of the transcription
        if checkForWakeWord(in: transcription) {
            // Check cooldown to prevent rapid re-triggering
            let now = Date()
            guard now.timeIntervalSince(lastWakeWordTime) >= wakeWordCooldown else {
                logger.debug("Wake word detected but in cooldown period")
                return
            }
            lastWakeWordTime = now

            logger.info("Wake word detected in: '\(transcription)'")
            onWakeWordDetected?()

            // Stop listening - will be resumed after recording completes
            stopListening()
        }
    }

    /// Check if the transcription starts with or contains the wake word
    private func checkForWakeWord(in text: String) -> Bool {
        let wakeWord = WakeWordDefaults.wakeWord.lowercased()
        let normalizedText = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if text starts with wake word (most reliable)
        if normalizedText.hasPrefix(wakeWord) {
            // Make sure it's a whole word
            let afterWakeWord = normalizedText.dropFirst(wakeWord.count)
            if afterWakeWord.isEmpty || afterWakeWord.first?.isWhitespace == true || afterWakeWord.first?.isPunctuation == true {
                return true
            }
        }

        // Also check if wake word appears as a standalone word anywhere
        // This helps catch cases where there's some noise before the wake word
        let words = normalizedText.components(separatedBy: .whitespacesAndNewlines)
        for (index, word) in words.enumerated() {
            let cleanWord = word.trimmingCharacters(in: .punctuationCharacters)
            if cleanWord == wakeWord {
                // Only trigger if it's near the beginning (within first 3 words)
                if index < 3 {
                    return true
                }
            }
        }

        return false
    }
}
