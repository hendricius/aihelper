import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "ScreenshotSessionExporter")

/// Stateless helpers that turn a session folder into hand-off files. They work
/// on any `(session, folder)` pair – the live session of `ScreenshotNotesStore`
/// as well as archived sessions shown in the history – so everything can be
/// re-exported later without touching the session that is currently open.
enum ScreenshotSessionExporter {
    static let sessionFileName = "session.json"
    static let notesFileName = "notes.md"
    static let pdfFileName = "notes.pdf"

    // MARK: - Paths

    static func sessionFileURL(in folder: URL) -> URL {
        folder.appendingPathComponent(sessionFileName)
    }

    static func notesURL(in folder: URL) -> URL {
        folder.appendingPathComponent(notesFileName)
    }

    static func pdfURL(in folder: URL) -> URL {
        folder.appendingPathComponent(pdfFileName)
    }

    /// ZIP next to the session folder: <root>/<session-name>.zip
    static func zipURL(for folder: URL) -> URL {
        folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".zip")
    }

    // MARK: - session.json

    static func loadSession(in folder: URL) -> ScreenshotSession? {
        guard let data = try? Data(contentsOf: sessionFileURL(in: folder)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let session = try? decoder.decode(ScreenshotSession.self, from: data) {
            return session
        }
        // Sessions written before dates were encoded as ISO 8601
        return try? JSONDecoder().decode(ScreenshotSession.self, from: data)
    }

    static func saveSession(_ session: ScreenshotSession, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        try data.write(to: sessionFileURL(in: folder), options: .atomic)
    }

    // MARK: - Markdown

    /// Markdown with absolute image paths, ready to paste into an agent prompt.
    static func markdown(for session: ScreenshotSession, folder: URL) -> String {
        ScreenshotMarkdownExporter.markdown(for: session, folder: folder)
    }

    static func writeNotes(for session: ScreenshotSession, folder: URL) throws {
        try markdown(for: session, folder: folder).write(to: notesURL(in: folder), atomically: true, encoding: .utf8)
    }

    // MARK: - PDF

    /// Renders the whole session into one PDF (images embedded). Defaults to
    /// notes.pdf inside the session folder.
    @discardableResult
    static func writePDF(for session: ScreenshotSession, folder: URL, to url: URL? = nil) throws -> URL {
        guard !session.captures.isEmpty else { throw ScreenshotNotesError.emptySession }
        let target = url ?? pdfURL(in: folder)
        guard let data = ScreenshotPDFExporter.pdfData(for: session, folder: folder) else {
            throw ScreenshotNotesError.writeFailed("PDF rendering failed")
        }
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            throw ScreenshotNotesError.writeFailed(error.localizedDescription)
        }
        logger.info("Wrote PDF (\(data.count) bytes) to \(target.path)")
        return target
    }

    /// notes.pdf of the folder, (re)rendered when it is missing or older than session.json.
    static func ensurePDF(for session: ScreenshotSession, folder: URL) throws -> URL {
        let pdf = pdfURL(in: folder)
        if isFresh(pdf, comparedTo: sessionFileURL(in: folder)) { return pdf }
        return try writePDF(for: session, folder: folder)
    }

    // MARK: - ZIP

    /// Packs the session into one ZIP: notes.md (relative paths), all images
    /// and notes.pdf. Writes to `url` or the ZIP next to the folder.
    @discardableResult
    static func writeZip(for session: ScreenshotSession, folder: URL, to url: URL? = nil) throws -> URL {
        guard !session.captures.isEmpty else { throw ScreenshotNotesError.emptySession }
        let target = url ?? zipURL(for: folder)
        let fm = FileManager.default

        // Stage a copy so the ZIP gets a portable notes.md without touching the folder
        let staging = try stagePortableCopy(for: session, folder: folder)
        defer { try? fm.removeItem(at: staging.deletingLastPathComponent()) }

        try? fm.removeItem(at: target)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--norsrc", "--keepParent", staging.path, target.path]
        ditto.standardOutput = Pipe()
        ditto.standardError = Pipe()
        do {
            try ditto.run()
        } catch {
            throw ScreenshotNotesError.writeFailed("ditto failed to start: \(error.localizedDescription)")
        }
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0, fm.fileExists(atPath: target.path) else {
            throw ScreenshotNotesError.writeFailed("ZIP creation failed (ditto exit \(ditto.terminationStatus))")
        }
        logger.info("Wrote ZIP to \(target.path)")
        return target
    }

    /// The session ZIP, (re)built when it is missing or older than session.json.
    /// Makes sure the embedded notes.pdf is current first.
    static func ensureZip(for session: ScreenshotSession, folder: URL) throws -> URL {
        let zip = zipURL(for: folder)
        if isFresh(zip, comparedTo: sessionFileURL(in: folder)) { return zip }
        _ = try ensurePDF(for: session, folder: folder)
        return try writeZip(for: session, folder: folder)
    }

    /// Files that belong in ZIPs / VM copies: images and the PDF (not session.json / previews).
    static func isSessionAsset(_ name: String) -> Bool {
        guard !name.hasPrefix(".") else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg"].contains(ext) || name == pdfFileName
    }

    /// Copies images + PDF into a temp folder named like the session and writes a
    /// notes.md with relative paths next to them. Caller removes the parent dir.
    static func stagePortableCopy(for session: ScreenshotSession, folder: URL) throws -> URL {
        let fm = FileManager.default
        let stagingRoot = fm.temporaryDirectory.appendingPathComponent("aihelper_stage_\(UUID().uuidString)", isDirectory: true)
        let staging = stagingRoot.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let contents = try fm.contentsOfDirectory(atPath: folder.path)
            for name in contents where isSessionAsset(name) {
                try fm.copyItem(at: folder.appendingPathComponent(name), to: staging.appendingPathComponent(name))
            }
            let portable = ScreenshotMarkdownExporter.markdown(for: session, folder: folder, pathStyle: .relative)
            try portable.write(to: staging.appendingPathComponent(notesFileName), atomically: true, encoding: .utf8)
        } catch {
            try? fm.removeItem(at: stagingRoot)
            throw ScreenshotNotesError.writeFailed(error.localizedDescription)
        }
        return staging
    }

    // MARK: - Renumbering

    /// Compacts capture indices to 1…n after a deletion and renames the files
    /// (`%03d.jpg`, `%03d-annotated.jpg`, `%03d-region-*.jpg`) accordingly, so
    /// headings, markers and file names stay in sync. Ascending order is safe:
    /// every target prefix was freed by the deletion or the previous rename.
    static func renumber(_ captures: [ScreenshotCapture], folder: URL) -> [ScreenshotCapture] {
        let fm = FileManager.default
        var result = captures
        for i in result.indices {
            let newIndex = i + 1
            guard result[i].index != newIndex else { continue }
            let oldPrefix = String(format: "%03d", result[i].index)
            let newPrefix = String(format: "%03d", newIndex)
            if let contents = try? fm.contentsOfDirectory(atPath: folder.path) {
                for name in contents where name.hasPrefix(oldPrefix + ".") || name.hasPrefix(oldPrefix + "-") {
                    let newName = newPrefix + name.dropFirst(oldPrefix.count)
                    let target = folder.appendingPathComponent(newName)
                    // The slot was freed by the deletion; anything still there is an orphan
                    try? fm.removeItem(at: target)
                    try? fm.moveItem(at: folder.appendingPathComponent(name), to: target)
                }
            }
            result[i].index = newIndex
            result[i].imageFileName = newPrefix + result[i].imageFileName.dropFirst(oldPrefix.count)
            if let annotated = result[i].annotatedFileName {
                result[i].annotatedFileName = newPrefix + annotated.dropFirst(oldPrefix.count)
            }
        }
        return result
    }

    // MARK: - Clipboard

    /// Puts a file on the clipboard so ⌘V attaches it (claude.ai, Finder, Mail…)
    /// or pastes its path (terminals).
    static func copyToClipboard(fileURL: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        ScreenshotNotesLog.log("Clipboard: file \(fileURL.path)")
    }

    static func copyMarkdownToClipboard(for session: ScreenshotSession, folder: URL) {
        let text = markdown(for: session, folder: folder)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ScreenshotNotesLog.log("Clipboard: markdown text (\(text.count) chars)")
    }

    // MARK: - Helpers

    /// True when `file` exists and is at least as new as `reference`.
    private static func isFresh(_ file: URL, comparedTo reference: URL) -> Bool {
        let fm = FileManager.default
        guard let fileDate = (try? fm.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date else { return false }
        guard let refDate = (try? fm.attributesOfItem(atPath: reference.path))?[.modificationDate] as? Date else { return true }
        return fileDate >= refDate
    }

    /// Total size of the files in a session folder plus its ZIP.
    static func byteSize(of folder: URL) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        if let contents = try? fm.contentsOfDirectory(atPath: folder.path) {
            for name in contents {
                let size = (try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path))?[.size] as? Int64 ?? 0
                total += size
            }
        }
        let zip = zipURL(for: folder)
        total += (try? fm.attributesOfItem(atPath: zip.path))?[.size] as? Int64 ?? 0
        return total
    }
}
