import Foundation
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "TranscriptionStore")

class TranscriptionStore: ObservableObject {
    @Published var transcriptions: [Transcription] = []

    private let maxStoredTranscriptions = 100

    /// Where the archive lives. Injectable so tests can never reach the real one:
    /// `clearAll()` deletes every transcription *and* its audio, which is not something
    /// a test run may do to a real user's history.
    private let defaults: UserDefaults
    private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = "transcriptions") {
        self.defaults = defaults
        self.storageKey = storageKey
        logger.info("Initializing TranscriptionStore...")
        load()
        logger.info("TranscriptionStore initialized with \(self.transcriptions.count) transcriptions")
    }

    func add(_ transcription: Transcription) {
        logger.debug("Adding transcription: \(transcription.text.prefix(50))...")
        transcriptions.insert(transcription, at: 0)

        // Limit storage - delete audio files for evicted transcriptions
        if transcriptions.count > maxStoredTranscriptions {
            let evicted = transcriptions[maxStoredTranscriptions...]
            for t in evicted {
                if let audioFile = t.audioFileName {
                    AudioFileManager.deleteAudio(fileName: audioFile)
                }
            }
            let removed = transcriptions.count - maxStoredTranscriptions
            transcriptions = Array(transcriptions.prefix(maxStoredTranscriptions))
            logger.debug("Removed \(removed) old transcriptions to stay under limit")
        }

        save()
    }

    func remove(_ transcription: Transcription) {
        if let audioFile = transcription.audioFileName {
            AudioFileManager.deleteAudio(fileName: audioFile)
        }
        let countBefore = transcriptions.count
        transcriptions.removeAll { $0.id == transcription.id }
        if transcriptions.count < countBefore {
            logger.debug("Removed transcription")
            save()
        }
    }

    func clearAll() {
        logger.info("Clearing all transcriptions")
        AudioFileManager.deleteAllAudio()
        transcriptions.removeAll()
        save()
    }

    private func save() {
        do {
            let encoded = try JSONEncoder().encode(transcriptions)
            defaults.set(encoded, forKey: storageKey)
            logger.debug("Saved \(self.transcriptions.count) transcriptions")
        } catch {
            logger.error("Failed to save transcriptions: \(error.localizedDescription)")
        }
    }

    private func load() {
        do {
            if let data = defaults.data(forKey: storageKey) {
                transcriptions = try JSONDecoder().decode([Transcription].self, from: data)
                logger.info("Loaded \(self.transcriptions.count) transcriptions from storage")
            }
        } catch {
            logger.error("Failed to decode transcriptions: \(error.localizedDescription). Clearing corrupted data.")
            defaults.removeObject(forKey: storageKey)
            transcriptions = []
        }
    }
}
