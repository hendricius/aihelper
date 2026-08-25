import Foundation

/// Bridges the app-wide ⌃⌥⌘⇧R recording into Screenshot Notes: if the user is
/// still recording when they hit "Done"/"Save", the recording is stopped, the
/// transcription awaited and handed back so it lands in the note.
@MainActor
enum GlobalDictationBridge {
    static var isRecording: Bool {
        AppState.shared.audioRecorder.isRecording
    }

    static var isProcessing: Bool {
        let manager = AppState.shared.recordingManager
        return manager.isTranscribing || manager.isFormatting
    }

    /// Stops a running global recording (if any) and returns the resulting
    /// transcription text. Returns nil when nothing was recording or it failed.
    static func stopAndCollect(timeout: TimeInterval = 45) async -> String? {
        let manager = AppState.shared.recordingManager
        let store = AppState.shared.transcriptionStore
        let before = store.transcriptions.first?.id

        if isRecording {
            ScreenshotNotesLog.log("Global recording still running – stopping it for the note")
            manager.stopRecordingAndProcess()
        } else if !isProcessing {
            return nil
        } else {
            ScreenshotNotesLog.log("Global transcription still processing – waiting for it")
        }

        let start = Date()
        // Wait for processing to finish and the new transcription to appear
        while Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(for: .milliseconds(120))
            let newest = store.transcriptions.first
            if !isProcessing, newest?.id != before {
                let text = newest?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                ScreenshotNotesLog.log("Global transcription collected (\(text.count) chars)")
                return text.isEmpty ? nil : text
            }
            if !isProcessing, !isRecording, Date().timeIntervalSince(start) > 3, newest?.id == before {
                // Processing ended without a new transcription (too short / error)
                ScreenshotNotesLog.log("Global recording ended without transcription")
                return nil
            }
        }
        ScreenshotNotesLog.error("Timed out waiting for global transcription")
        return nil
    }
}
