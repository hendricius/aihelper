import Foundation
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "DictationController")

/// Small push-to-talk helper: records with its own AudioRecorder, sends the
/// audio through the regular transcription pipeline and hands back the text.
/// Used for dictating screenshot notes without going through RecordingManager
/// (which pastes into the frontmost app).
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
    }

    @Published private(set) var state: State = .idle
    @Published var errorMessage: String?

    private let recorder = AudioRecorder()
    private var completion: ((String) -> Void)?
    private var transcriptionTask: Task<Void, Never>?

    var isBusy: Bool { state != .idle }

    /// Starts recording, or – if already recording – stops and transcribes.
    /// `onText` is always called once the transcription ends – with the text,
    /// or with "" when it failed or was empty (so callers can track completion).
    func toggle(onText: @escaping (String) -> Void) {
        switch state {
        case .idle:
            start(onText: onText)
        case .recording:
            stopAndTranscribe()
        case .transcribing:
            break
        }
    }

    func cancel() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        if state == .recording {
            recorder.cancelRecording()
        }
        completion = nil
        state = .idle
    }

    private func start(onText: @escaping (String) -> Void) {
        errorMessage = nil
        do {
            try recorder.startRecording(withStopWordDetection: false)
            completion = onText
            state = .recording
            logger.info("Dictation started")
            ScreenshotNotesLog.log("Dictation recording started")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Dictation could not start: \(error.localizedDescription)")
            ScreenshotNotesLog.error("Dictation could not start: \(error)")
        }
    }

    private func stopAndTranscribe() {
        guard let url = recorder.stopRecording() else {
            // Too short or failed – nothing to transcribe
            ScreenshotNotesLog.log("Dictation stopped without audio (too short)")
            state = .idle
            let handler = completion
            completion = nil
            handler?("")
            return
        }
        ScreenshotNotesLog.log("Dictation stopped, transcribing \(url.lastPathComponent)")

        state = .transcribing
        let handler = completion
        completion = nil

        transcriptionTask = Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let promptHint = VocabularyDefaults.buildPromptHint(additionalContext: nil)
                let result = try await TranscriptionServiceRouter.shared.transcribe(audioURL: url, promptHint: promptHint)
                guard !Task.isCancelled else { return }
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                logger.info("Dictation transcribed \(text.count) chars")
                ScreenshotNotesLog.log("Dictation transcribed \(text.count) chars")
                self?.state = .idle
                handler?(text)
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Dictation transcription failed: \(error.localizedDescription)")
                ScreenshotNotesLog.error("Dictation transcription failed: \(error)")
                self?.state = .idle
                self?.errorMessage = error.localizedDescription
                handler?("")
            }
        }
    }
}
