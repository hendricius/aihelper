import Foundation
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "AudioFileManager")

enum AudioFileManager {
    private static let audioDirectoryName = "audio"
    private static let appSupportSubdir = "com.aihelper.app"

    static var audioDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent(appSupportSubdir)
            .appendingPathComponent(audioDirectoryName)
    }

    static func ensureDirectoryExists() {
        let dir = audioDirectory
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                logger.info("Created audio directory: \(dir.path)")
            } catch {
                logger.error("Failed to create audio directory: \(error.localizedDescription)")
            }
        }
    }

    /// Copy temp audio file to persistent storage
    /// - Returns: The filename (not full path) of the persisted file, or nil on failure
    static func persistAudio(from sourceURL: URL, transcriptionId: UUID) -> String? {
        ensureDirectoryExists()

        let fileName = "\(transcriptionId.uuidString).m4a"
        let destinationURL = audioDirectory.appendingPathComponent(fileName)

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            logger.info("Persisted audio: \(fileName)")
            return fileName
        } catch {
            logger.error("Failed to persist audio: \(error.localizedDescription)")
            return nil
        }
    }

    /// Resolve a filename to its full URL
    static func audioURL(for fileName: String) -> URL? {
        let url = audioDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    /// Delete a single audio file
    static func deleteAudio(fileName: String) {
        let url = audioDirectory.appendingPathComponent(fileName)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                logger.debug("Deleted audio: \(fileName)")
            }
        } catch {
            logger.error("Failed to delete audio \(fileName): \(error.localizedDescription)")
        }
    }

    /// Delete all audio files
    static func deleteAllAudio() {
        let dir = audioDirectory
        do {
            if FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.removeItem(at: dir)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                logger.info("Deleted all audio files")
            }
        } catch {
            logger.error("Failed to delete all audio: \(error.localizedDescription)")
        }
    }

    /// Total size of all stored audio files in bytes
    static func totalStorageBytes() -> Int {
        let dir = audioDirectory
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }

        var total = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                total += size
            }
        }
        return total
    }
}
