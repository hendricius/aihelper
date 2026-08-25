import Foundation
import os.log

/// File log for the Screenshot Notes feature: ~/Library/Logs/AIHelper/screenshot-notes.log
/// Mirrors into the unified log. Kept deliberately simple and synchronous so the
/// last line survives a crash.
enum ScreenshotNotesLog {
    private static let logger = Logger(subsystem: "com.aihelper.app", category: "ScreenshotNotes")
    private static let queue = DispatchQueue(label: "com.aihelper.screenshotnotes.log")
    private static let maxBytes = 2_000_000

    static var fileURL: URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("AIHelper", isDirectory: true)
        return logs.appendingPathComponent("screenshot-notes.log")
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func log(_ message: String, file: String = #fileID, line: Int = #line) {
        let origin = file.split(separator: "/").last.map(String.init) ?? file
        let text = "[\(formatter.string(from: Date()))] \(origin):\(line) \(message)\n"
        logger.info("\(message, privacy: .public)")
        queue.sync {
            write(text)
        }
    }

    static func error(_ message: String, file: String = #fileID, line: Int = #line) {
        log("ERROR \(message)", file: file, line: line)
    }

    private static func write(_ text: String) {
        let url = fileURL
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            // Simple rotation
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > maxBytes {
                let old = url.deletingPathExtension().appendingPathExtension("1.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
                fm.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            logger.error("Log write failed: \(error.localizedDescription)")
        }
    }

    /// Writes ObjC exceptions (the usual cause of AppKit crashes) to the log
    /// before the process dies.
    static func installUncaughtExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.prefix(25).joined(separator: "\n    ")
            ScreenshotNotesLog.log("UNCAUGHT EXCEPTION \(exception.name.rawValue): \(exception.reason ?? "-")\n    \(stack)")
        }
        log("App started, exception handler installed (pid \(ProcessInfo.processInfo.processIdentifier))")
    }
}
