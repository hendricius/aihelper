import Foundation
import AppKit
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "RecordingManager")

enum RecordingMode {
    case transcription
    case email
}

@MainActor
class RecordingManager: ObservableObject {
    @Published var isTranscribing = false
    @Published var isFormatting = false
    @Published var isRetrying = false
    @Published var errorMessage: String?
    @Published var showCopiedFeedback = false
    @Published var currentMode: RecordingMode = .transcription

    /// When true, the next transcription will also be formatted
    private var formattingModeEnabled = false

    /// When true, the next transcription will be rewritten as a casual message
    private var casualMessageModeEnabled = false

    /// Flag to track if recording was stopped by stop word detection
    private var wasTriggeredByStopWord = false

    /// The current processing task (transcription/formatting) - stored so it can be cancelled
    private var processingTask: Task<Void, Never>?

    let audioRecorder: AudioRecorder
    let transcriptionStore: TranscriptionStore
    let failedRequestStore: FailedRequestStore

    // Stores the original email text (from clipboard) when starting email mode
    private var originalEmailContext: String?

    init(audioRecorder: AudioRecorder, transcriptionStore: TranscriptionStore, failedRequestStore: FailedRequestStore) {
        self.audioRecorder = audioRecorder
        self.transcriptionStore = transcriptionStore
        self.failedRequestStore = failedRequestStore

        // Set up stop word detection callback
        setupStopWordCallback()
    }

    private func setupStopWordCallback() {
        audioRecorder.onStopWordDetected = { [weak self] in
            Task { @MainActor in
                self?.handleStopWordDetected()
            }
        }
    }

    private func handleStopWordDetected() {
        guard audioRecorder.isRecording else { return }
        logger.info("Stop word detected - stopping recording")
        wasTriggeredByStopWord = true
        stopRecordingAndProcess()
    }

    /// Returns true if currently in formatting mode
    var isFormattingMode: Bool {
        formattingModeEnabled
    }

    /// Returns true if currently in casual message mode
    var isCasualMessageMode: Bool {
        casualMessageModeEnabled
    }

    func toggleRecording() {
        toggleRecording(mode: .transcription)
    }

    func toggleRecording(mode: RecordingMode) {
        logger.info("toggleRecording called with mode: \(String(describing: mode)), isRecording: \(self.audioRecorder.isRecording)")
        if audioRecorder.isRecording {
            logger.info("Stopping recording...")
            stopRecordingAndProcess()
        } else {
            logger.info("Starting recording in \(String(describing: mode)) mode...")
            currentMode = mode
            formattingModeEnabled = false
            casualMessageModeEnabled = false
            startRecording()
        }
    }

    func toggleFormattingRecording() {
        logger.info("toggleFormattingRecording called, isRecording: \(self.audioRecorder.isRecording)")
        if audioRecorder.isRecording {
            logger.info("Stopping recording (formatting mode)...")
            stopRecordingAndProcess()
        } else {
            logger.info("Starting recording (formatting mode)...")
            currentMode = .transcription
            casualMessageModeEnabled = false
            formattingModeEnabled = true
            startRecording()
        }
    }

    func toggleCasualMessageRecording() {
        logger.info("toggleCasualMessageRecording called, isRecording: \(self.audioRecorder.isRecording)")
        if audioRecorder.isRecording {
            logger.info("Stopping recording (casual message mode)...")
            stopRecordingAndProcess()
        } else {
            logger.info("Starting recording (casual message mode)...")
            currentMode = .transcription
            formattingModeEnabled = false
            casualMessageModeEnabled = true
            startRecording()
        }
    }

    func startRecording() {
        logger.debug("startRecording() called in \(String(describing: self.currentMode)) mode")
        errorMessage = nil

        // For email mode, capture the currently selected text
        if currentMode == .email {
            originalEmailContext = captureSelectedText()
            if let context = originalEmailContext {
                logger.info("Captured email context: \(context.prefix(100))...")
            } else {
                logger.info("No text selected for email context")
            }
        } else {
            originalEmailContext = nil
        }

        do {
            try audioRecorder.startRecording()
            logger.info("Recording started successfully")
            let overlayState: OverlayState
            if casualMessageModeEnabled {
                overlayState = .recordingCasualMessage
            } else if currentMode == .email {
                overlayState = .recordingEmail
            } else {
                overlayState = .recording
            }
            StatusOverlay.shared.show(state: overlayState)
        } catch {
            logger.error("Failed to start recording: \(error.localizedDescription)")
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    /// Captures the currently selected text by simulating Cmd+C using AppleScript
    private func captureSelectedText() -> String? {
        logger.debug("captureSelectedText() starting...")

        // Save current clipboard content
        let pasteboard = NSPasteboard.general
        let previousContent = pasteboard.string(forType: .string)
        logger.debug("Previous clipboard content length: \(previousContent?.count ?? 0)")

        // Clear clipboard
        pasteboard.clearContents()

        // Use AppleScript to send Cmd+C - more reliable than CGEvent
        let script = """
            tell application "System Events"
                keystroke "c" using command down
            end tell
            """

        logger.debug("Executing AppleScript to send Cmd+C...")
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                logger.error("AppleScript error: \(error)")
            }
        }

        // Wait for the copy to complete (some apps are slow)
        Thread.sleep(forTimeInterval: 0.25)

        // Get the copied text
        let selectedText = pasteboard.string(forType: .string)
        logger.debug("After Cmd+C, clipboard content length: \(selectedText?.count ?? 0)")

        // Restore previous clipboard content if we didn't get new text
        if selectedText == nil || selectedText?.isEmpty == true {
            logger.warning("No text was copied - Cmd+C may have failed")
            if let previous = previousContent {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
            return nil
        }

        logger.info("Successfully captured \(selectedText?.count ?? 0) characters")
        return selectedText
    }

    func stopRecordingAndProcess() {
        logger.debug("stopRecordingAndProcess() called")

        // Capture recording duration before stopping (still valid until next startRecording)
        let recordingDuration = audioRecorder.recordingTime

        guard let audioURL = audioRecorder.stopRecording() else {
            logger.warning("No audio recorded")
            errorMessage = "No audio recorded"
            formattingModeEnabled = false
            casualMessageModeEnabled = false
            wasTriggeredByStopWord = false
            StatusOverlay.shared.hide()
            return
        }

        // Capture audio file size
        let audioFileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? nil

        let shouldFormat = formattingModeEnabled
        let shouldCasualMessage = casualMessageModeEnabled
        let isEmailMode = currentMode == .email
        let emailContext = originalEmailContext
        let triggeredByStopWord = wasTriggeredByStopWord
        formattingModeEnabled = false
        casualMessageModeEnabled = false
        wasTriggeredByStopWord = false

        logger.info("Recording stopped, starting transcription (formatting: \(shouldFormat), casualMessage: \(shouldCasualMessage), emailMode: \(isEmailMode))")
        isTranscribing = true
        errorMessage = nil
        StatusOverlay.shared.show(state: .transcribing)

        processingTask = Task {
            do {
                // Check for cancellation before starting
                try Task.checkCancellation()

                // Generate UUID early so we can persist audio with matching filename
                let transcriptionId = UUID()

                // Persist audio file before transcription (temp file may be cleaned up)
                let audioFileName = AudioFileManager.persistAudio(from: audioURL, transcriptionId: transcriptionId)

                // Build prompt hint with vocabulary and optional email context
                var additionalContext: String?
                if isEmailMode, let context = emailContext {
                    let names = NameExtractor.extractNames(from: context)
                    if !names.isEmpty {
                        additionalContext = "Names mentioned: \(names.joined(separator: ", "))"
                    }
                }

                // Always include custom vocabulary to help with domain-specific terms
                let whisperPromptHint = VocabularyDefaults.buildPromptHint(additionalContext: additionalContext)
                logger.info("Using Whisper prompt hint: \(whisperPromptHint.prefix(100))...")

                logger.debug("Calling transcription service...")
                let transcriptionStart = Date()
                let transcriptionResult = try await TranscriptionServiceRouter.shared.transcribe(
                    audioURL: audioURL,
                    promptHint: whisperPromptHint
                )
                var text = transcriptionResult.text
                let transcriptionApiLog = transcriptionResult.apiLog
                let transcriptionMs = Int(Date().timeIntervalSince(transcriptionStart) * 1000)
                logger.info("Transcription completed in \(transcriptionMs)ms: \(text.prefix(50))...")

                // Check for cancellation after transcription
                try Task.checkCancellation()

                // Save raw transcription for debugging before any formatting
                let rawTranscriptionText = text

                // Track metadata for debugging
                var appliedFormatting = false
                var usedPromptName: String?
                var formattingMs: Int?
                var formattingApiLog: APICallLog?

                // Check for cancellation before formatting
                try Task.checkCancellation()

                // Email mode always applies formatting with the email prompt
                if isEmailMode {
                    logger.info("Email mode - applying email formatting prompt...")
                    isTranscribing = false
                    isFormatting = true
                    StatusOverlay.shared.show(state: .formatting)

                    do {
                        // Build the email prompt with placeholders replaced
                        let emailPromptTemplate = UserDefaults.standard.string(forKey: "email_format_prompt") ?? EmailDefaults.prompt
                        let emailPrompt = emailPromptTemplate
                            .replacingOccurrences(of: EmailDefaults.selectedTextPlaceholder, with: emailContext ?? "(No email selected)")
                            .replacingOccurrences(of: EmailDefaults.transcriptionPlaceholder, with: text)

                        logger.info("Email prompt built, calling formatting service...")
                        let fmtStart = Date()
                        let fmtResult = try await FormattingService.shared.improveFormatting(text: text, customPrompt: emailPrompt)
                        text = fmtResult.text
                        formattingApiLog = fmtResult.apiLog
                        formattingMs = Int(Date().timeIntervalSince(fmtStart) * 1000)
                        logger.info("Email formatting completed in \(formattingMs ?? 0)ms: \(text.prefix(50))...")
                        appliedFormatting = true
                        usedPromptName = "Email Reply"
                    } catch let formattingError as FormattingError where formattingError.isRetryable {
                        logger.warning("Email formatting failed with retryable error, saving for retry")
                        let failedRequest = FailedRequest.formatting(
                            text: text,
                            errorMessage: formattingError.localizedDescription
                        )
                        failedRequestStore.add(failedRequest)
                        errorMessage = "Connection lost. Your text has been saved - tap Retry when connected."
                        isTranscribing = false
                        isFormatting = false
                        StatusOverlay.shared.hide()
                        return
                    }
                    isFormatting = false
                } else if shouldCasualMessage {
                    logger.info("Casual message mode enabled, rewriting text...")
                    isTranscribing = false
                    isFormatting = true
                    StatusOverlay.shared.show(state: .formatting)

                    do {
                        let fmtStart = Date()
                        let fmtResult = try await FormattingService.shared.improveFormatting(text: text, customPrompt: FormattingService.casualMessagePrompt)
                        text = fmtResult.text
                        formattingApiLog = fmtResult.apiLog
                        formattingMs = Int(Date().timeIntervalSince(fmtStart) * 1000)
                        logger.info("Casual message formatting completed in \(formattingMs ?? 0)ms: \(text.prefix(50))...")
                        appliedFormatting = true
                        usedPromptName = "Message"
                    } catch let formattingError as FormattingError where formattingError.isRetryable {
                        logger.warning("Casual message formatting failed with retryable error, saving for retry")
                        let failedRequest = FailedRequest.formatting(
                            text: text,
                            errorMessage: formattingError.localizedDescription
                        )
                        failedRequestStore.add(failedRequest)
                        errorMessage = "Connection lost. Your text has been saved - tap Retry when connected."
                        isTranscribing = false
                        isFormatting = false
                        StatusOverlay.shared.hide()
                        return
                    }
                    isFormatting = false
                } else if shouldFormat {
                    logger.info("Formatting mode enabled, improving text...")
                    isTranscribing = false
                    isFormatting = true
                    StatusOverlay.shared.show(state: .formatting)

                    do {
                        // Use the default casual-message formatting prompt
                        let customPrompt: String? = nil
                        let fmtStart = Date()
                        let fmtResult = try await FormattingService.shared.improveFormatting(text: text, customPrompt: customPrompt)
                        text = fmtResult.text
                        formattingApiLog = fmtResult.apiLog
                        formattingMs = Int(Date().timeIntervalSince(fmtStart) * 1000)
                        logger.info("Formatting completed in \(formattingMs ?? 0)ms: \(text.prefix(50))...")
                        appliedFormatting = true
                    } catch let formattingError as FormattingError where formattingError.isRetryable {
                        // Save the transcribed text for retry
                        logger.warning("Formatting failed with retryable error, saving for retry")
                        let failedRequest = FailedRequest.formatting(
                            text: text,
                            errorMessage: formattingError.localizedDescription
                        )
                        failedRequestStore.add(failedRequest)
                        errorMessage = "Connection lost. Your text has been saved - tap Retry when connected."
                        isTranscribing = false
                        isFormatting = false
                        StatusOverlay.shared.hide()
                        return
                    }
                    isFormatting = false
                }

                // Strip stop word if recording was triggered by stop word detection
                if triggeredByStopWord {
                    text = stripStopWord(from: text)
                    logger.info("Text after stop word stripping: \(text.prefix(50))...")
                }

                // Determine the transcription mode for metadata
                let transcriptionMode: TranscriptionMode
                if isEmailMode {
                    transcriptionMode = .email
                } else if shouldCasualMessage {
                    transcriptionMode = .casualMessage
                } else if appliedFormatting {
                    transcriptionMode = .formatting
                } else {
                    transcriptionMode = .transcription
                }

                let transcription = Transcription(
                    id: transcriptionId,
                    text: text,
                    date: Date(),
                    mode: transcriptionMode,
                    formattingApplied: appliedFormatting,
                    promptUsed: usedPromptName,
                    originalContext: isEmailMode ? emailContext : nil,
                    rawTranscription: appliedFormatting ? rawTranscriptionText : nil,
                    audioFileName: audioFileName,
                    audioDurationSeconds: recordingDuration,
                    audioFileSizeBytes: audioFileSize,
                    transcriptionDurationMs: transcriptionMs,
                    formattingDurationMs: formattingMs,
                    transcriptionEngine: "cloud",
                    transcriptionAPILog: transcriptionApiLog,
                    formattingAPILog: formattingApiLog
                )
                transcriptionStore.add(transcription)
                isTranscribing = false
                isFormatting = false
                copyToClipboard(text)

                // If triggered by stop word and auto-paste is enabled, paste and press return
                if triggeredByStopWord && StopWordDefaults.autoPasteEnabled {
                    logger.info("Stop word triggered - executing paste and return")
                    pasteAndReturn()
                }

                logger.debug("Showing completed overlay")
                StatusOverlay.shared.show(state: .completed)
            } catch let whisperError as WhisperError where whisperError.isRetryable {
                // Save audio data for retry
                logger.warning("Transcription failed with retryable error, saving for retry")
                if let audioData = try? Data(contentsOf: audioURL) {
                    let failedRequest = FailedRequest.transcription(
                        audioData: audioData,
                        errorMessage: whisperError.localizedDescription,
                        formattingEnabled: shouldFormat
                    )
                    failedRequestStore.add(failedRequest)
                    errorMessage = "Connection lost. Your recording has been saved - tap Retry when connected."
                } else {
                    errorMessage = "Processing failed: \(whisperError.localizedDescription)"
                }
                isTranscribing = false
                isFormatting = false
                StatusOverlay.shared.hide()
            } catch is CancellationError {
                // Task was cancelled by user - state already reset by cancelProcessing()
                logger.info("Processing task was cancelled")
            } catch {
                logger.error("Processing failed: \(error.localizedDescription)")
                errorMessage = "Processing failed: \(error.localizedDescription)"
                isTranscribing = false
                isFormatting = false
                StatusOverlay.shared.hide()
            }
        }
    }

    /// Cancel the current transcription/formatting processing
    func cancelProcessing() {
        guard isTranscribing || isFormatting else {
            logger.debug("cancelProcessing called but nothing is processing")
            return
        }

        logger.info("Cancelling processing...")
        processingTask?.cancel()
        processingTask = nil

        isTranscribing = false
        isFormatting = false
        errorMessage = nil

        StatusOverlay.shared.showBrief(message: "Cancelled")
    }

    // Legacy method for compatibility
    func stopRecordingAndTranscribe() {
        stopRecordingAndProcess()
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents()
        pasteboard.setString(text, forType: .string)

        showCopiedFeedback = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            showCopiedFeedback = false
        }
    }

    // MARK: - Stop Word Support

    /// Paste clipboard contents and press Return using AppleScript
    private func pasteAndReturn() {
        logger.debug("Executing paste and return...")

        // Add a delay before executing to ensure all modifier keys from the
        // recording hotkey have been released. This prevents Terminal from
        // misinterpreting the keystroke (e.g., triggering full screen mode).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let script = """
                tell application "System Events"
                    delay 0.1
                    keystroke "v" using command down
                    delay 0.15
                    key code 36
                end tell
                """

            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                if let error = error {
                    logger.error("AppleScript paste+return error: \(error)")
                } else {
                    logger.info("Paste and return executed successfully")
                }
            }
        }
    }

    /// Strip trailing stop word from transcription text
    /// Only removes the stop word if it's at the end of the text
    /// - "Hello world over" -> "Hello world"
    /// - "Hello world over." -> "Hello world"
    /// - "Hello over world" -> "Hello over world" (unchanged)
    func stripStopWord(from text: String) -> String {
        let stopWord = StopWordDefaults.stopWord.lowercased()

        // Trim whitespace first
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for trailing punctuation and preserve it separately
        var trailingPunctuation = ""
        while let last = result.last, last.isPunctuation {
            trailingPunctuation = String(last) + trailingPunctuation
            result.removeLast()
        }

        // Now check if it ends with the stop word (case-insensitive)
        let lowercasedResult = result.lowercased()
        if lowercasedResult.hasSuffix(stopWord) {
            // Make sure it's a whole word (preceded by space or start of string)
            let prefixEndIndex = result.index(result.endIndex, offsetBy: -stopWord.count)
            if prefixEndIndex == result.startIndex || result[result.index(before: prefixEndIndex)] == " " {
                // Remove the stop word
                result = String(result[..<prefixEndIndex]).trimmingCharacters(in: .whitespaces)
                logger.debug("Stripped stop word '\(stopWord)' from transcription")
            }
        }

        return result
    }

    // MARK: - Retry Failed Requests

    func retryFailedRequest(_ request: FailedRequest) {
        logger.info("Retrying failed request: \(request.requestType.rawValue)")
        isRetrying = true
        errorMessage = nil

        Task {
            do {
                switch request.requestType {
                case .transcription:
                    guard let audioData = request.audioData else {
                        logger.error("No audio data in failed request")
                        errorMessage = "Failed to retry: No audio data found"
                        isRetrying = false
                        return
                    }
                    try await retryTranscription(
                        audioData: audioData,
                        formattingEnabled: request.formattingEnabled,
                        originalRequest: request
                    )

                case .formatting:
                    guard let text = request.text else {
                        logger.error("No text in failed request")
                        errorMessage = "Failed to retry: No text found"
                        isRetrying = false
                        return
                    }
                    try await retryFormatting(text: text, originalRequest: request)
                }
            } catch {
                logger.error("Retry failed: \(error.localizedDescription)")
                errorMessage = "Retry failed: \(error.localizedDescription)"
                isRetrying = false
            }
        }
    }

    private func retryTranscription(audioData: Data, formattingEnabled: Bool, originalRequest: FailedRequest) async throws {
        // Write audio data to a temporary file
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("retry_audio_\(UUID().uuidString).m4a")

        do {
            try audioData.write(to: tempURL)
        } catch {
            logger.error("Failed to write temporary audio file: \(error.localizedDescription)")
            throw error
        }

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        isTranscribing = true
        StatusOverlay.shared.show(state: .transcribing)

        do {
            let transcriptionResult = try await TranscriptionServiceRouter.shared.transcribe(audioURL: tempURL)
            var text = transcriptionResult.text
            let transcriptionApiLog = transcriptionResult.apiLog
            logger.info("Retry transcription completed: \(text.prefix(50))...")

            let rawText = text  // Save raw transcription before formatting
            var fmtApiLog: APICallLog?

            if formattingEnabled {
                isTranscribing = false
                isFormatting = true
                StatusOverlay.shared.show(state: .formatting)

                let customPrompt: String? = nil
                let fmtResult = try await FormattingService.shared.improveFormatting(text: text, customPrompt: customPrompt)
                text = fmtResult.text
                fmtApiLog = fmtResult.apiLog
                logger.info("Retry formatting completed: \(text.prefix(50))...")
                isFormatting = false
            }

            // Success - remove from failed requests and add to transcriptions
            failedRequestStore.remove(originalRequest)

            let transcription = Transcription(
                text: text,
                date: Date(),
                mode: formattingEnabled ? .formatting : .transcription,
                formattingApplied: formattingEnabled,
                promptUsed: nil,
                originalContext: nil,
                rawTranscription: formattingEnabled ? rawText : nil,
                transcriptionAPILog: transcriptionApiLog,
                formattingAPILog: fmtApiLog
            )
            transcriptionStore.add(transcription)
            copyToClipboard(text)

            isTranscribing = false
            isRetrying = false
            StatusOverlay.shared.show(state: .completed)
        } catch let whisperError as WhisperError where whisperError.isRetryable {
            // Still failing - update error message but keep the saved request
            logger.warning("Retry still failing with network error")
            errorMessage = "Still no connection. Please try again later."
            isTranscribing = false
            isFormatting = false
            isRetrying = false
            StatusOverlay.shared.hide()
        } catch let formattingError as FormattingError where formattingError.isRetryable {
            logger.warning("Retry formatting still failing with network error")
            errorMessage = "Still no connection. Please try again later."
            isTranscribing = false
            isFormatting = false
            isRetrying = false
            StatusOverlay.shared.hide()
        }
    }

    private func retryFormatting(text: String, originalRequest: FailedRequest) async throws {
        isFormatting = true
        StatusOverlay.shared.show(state: .formatting)

        do {
            let customPrompt: String? = nil
            let fmtResult = try await FormattingService.shared.improveFormatting(text: text, customPrompt: customPrompt)
            let formattedText = fmtResult.text
            logger.info("Retry formatting completed: \(formattedText.prefix(50))...")

            // Success - remove from failed requests and add to transcriptions
            failedRequestStore.remove(originalRequest)

            let transcription = Transcription(
                text: formattedText,
                date: Date(),
                mode: .formatting,
                formattingApplied: true,
                promptUsed: nil,
                originalContext: nil,
                rawTranscription: text,
                formattingAPILog: fmtResult.apiLog
            )
            transcriptionStore.add(transcription)
            copyToClipboard(formattedText)

            isFormatting = false
            isRetrying = false
            StatusOverlay.shared.show(state: .completed)
        } catch let formattingError as FormattingError where formattingError.isRetryable {
            logger.warning("Retry formatting still failing with network error")
            errorMessage = "Still no connection. Please try again later."
            isFormatting = false
            isRetrying = false
            StatusOverlay.shared.hide()
        }
    }

    func dismissFailedRequest(_ request: FailedRequest) {
        logger.info("Dismissing failed request")
        failedRequestStore.remove(request)
        if failedRequestStore.failedRequests.isEmpty {
            errorMessage = nil
        }
    }
}
