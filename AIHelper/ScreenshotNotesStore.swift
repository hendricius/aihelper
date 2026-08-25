import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "ScreenshotNotesStore")

enum ScreenshotNotesError: LocalizedError {
    case emptySession
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptySession:
            return "No screenshots in this session"
        case .writeFailed(let reason):
            return "Could not write notes: \(reason)"
        }
    }
}

/// Owns the current screenshot session: a folder on disk holding the images,
/// a `session.json` and a regenerated `notes.md`. Finished sessions stay on
/// disk and are listed by `ScreenshotHistoryStore`.
@MainActor
final class ScreenshotNotesStore: ObservableObject {
    static let shared = ScreenshotNotesStore()

    @Published private(set) var session: ScreenshotSession
    @Published private(set) var sessionFolder: URL

    private static let currentSessionKey = "screenshotNotes.currentSessionFolder"
    static let notesFileName = ScreenshotSessionExporter.notesFileName
    static let pdfFileName = ScreenshotSessionExporter.pdfFileName

    /// What `finishSession` puts on the clipboard (UserDefaults key).
    static let handoffFormatKey = "screenshotNotes.handoffFormat"
    /// "quick" (crosshair + HUD) or "editor" (full window) – UserDefaults key.
    static let captureModeKey = "screenshotNotes.captureMode"
    /// Start dictation automatically when the quick HUD appears – UserDefaults key.
    static let autoDictateKey = "screenshotNotes.autoDictate"
    /// Show the review window before ⌃⌥⌘⇧D exports – UserDefaults key (off by default).
    static let reviewBeforeExportKey = "screenshotNotes.reviewBeforeExport"

    static var reviewBeforeExportEnabled: Bool {
        UserDefaults.standard.bool(forKey: reviewBeforeExportKey)
    }

    enum CaptureMode: String, CaseIterable, Identifiable {
        case quick
        case editor

        var id: String { rawValue }

        var label: String {
            switch self {
            case .quick: return "Quick: crosshair + small note popup"
            case .editor: return "Editor window"
            }
        }

        static var current: CaptureMode {
            CaptureMode(rawValue: UserDefaults.standard.string(forKey: captureModeKey) ?? "") ?? .quick
        }
    }

    static var autoDictateEnabled: Bool {
        UserDefaults.standard.object(forKey: autoDictateKey) as? Bool ?? true
    }

    enum HandoffFormat: String, CaseIterable, Identifiable {
        case pdf
        case zip
        case markdown

        var id: String { rawValue }

        var label: String {
            switch self {
            case .pdf: return "PDF file (all images embedded) – recommended"
            case .zip: return "ZIP file (notes.md + images + PDF)"
            case .markdown: return "Markdown text only"
            }
        }

        static var current: HandoffFormat {
            HandoffFormat(rawValue: UserDefaults.standard.string(forKey: handoffFormatKey) ?? "") ?? .pdf
        }
    }

    private var thumbnailCache: [UUID: NSImage] = [:]
    private var cgImageCache: [UUID: CGImage] = [:]

    // MARK: - Init / persistence

    private init() {
        Self.migrateLegacyRootIfNeeded()
        if let restored = Self.restoreSession() {
            session = restored.session
            sessionFolder = restored.folder
            logger.info("Resumed screenshot session with \(restored.session.captures.count) captures at \(restored.folder.path)")
            ScreenshotNotesLog.log("Resumed session with \(restored.session.captures.count) captures: \(restored.folder.path)")
        } else {
            let fresh = ScreenshotSession()
            session = fresh
            sessionFolder = Self.makeSessionFolderURL(for: fresh)
        }
    }

    /// Where sessions, ZIPs and PDFs are written – UserDefaults key.
    static let outputFolderKey = "screenshotNotes.outputFolder"
    /// Lives in Application Support so sessions survive reboots (/tmp is purged by macOS).
    static let defaultOutputFolder = "~/Library/Application Support/AIHelper/ScreenshotNotes"
    /// Default of the first release; sessions found there are moved to `defaultOutputFolder` once.
    static let legacyOutputFolder = "/tmp/aihelper-screenshot-notes"

    static var rootFolder: URL {
        let configured = UserDefaults.standard.string(forKey: outputFolderKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path = configured.isEmpty ? defaultOutputFolder : configured
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// True when the output folder setting still points at the old /tmp default.
    private static var usesLegacyRootSetting: Bool {
        let configured = UserDefaults.standard.string(forKey: outputFolderKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return configured.isEmpty || configured == legacyOutputFolder
    }

    /// Moves sessions from the old /tmp default into Application Support so
    /// nothing is lost on the next reboot. Runs once per launch, is a no-op when
    /// the user configured their own folder or /tmp holds nothing.
    static func migrateLegacyRootIfNeeded() {
        guard usesLegacyRootSetting else { return }
        if UserDefaults.standard.string(forKey: outputFolderKey) == legacyOutputFolder {
            UserDefaults.standard.removeObject(forKey: outputFolderKey)
        }
        let fm = FileManager.default
        let legacy = URL(fileURLWithPath: legacyOutputFolder, isDirectory: true)
        guard let items = try? fm.contentsOfDirectory(atPath: legacy.path), !items.isEmpty else { return }
        let target = rootFolder
        guard target.standardizedFileURL != legacy.standardizedFileURL else { return }

        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            ScreenshotNotesLog.error("Could not create \(target.path) for migration: \(error.localizedDescription)")
            return
        }
        var moved = 0
        for name in items where !name.hasPrefix(".") {
            let source = legacy.appendingPathComponent(name)
            let destination = target.appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: source.path, isDirectory: &isDir)
            let isSession = isDir.boolValue && fm.fileExists(atPath: ScreenshotSessionExporter.sessionFileURL(in: source).path)
            let isZip = !isDir.boolValue && name.lowercased().hasSuffix(".zip")
            guard isSession || isZip, !fm.fileExists(atPath: destination.path) else { continue }
            do {
                try fm.moveItem(at: source, to: destination)
                moved += 1
            } catch {
                ScreenshotNotesLog.error("Could not move \(source.path): \(error.localizedDescription)")
            }
        }
        // The session that was open keeps working from its new location
        if let current = UserDefaults.standard.string(forKey: currentSessionKey), current.hasPrefix(legacy.path + "/") {
            let relocated = target.appendingPathComponent(String(current.dropFirst(legacy.path.count + 1))).path
            if fm.fileExists(atPath: relocated) {
                UserDefaults.standard.set(relocated, forKey: currentSessionKey)
            }
        }
        if moved > 0 {
            ScreenshotNotesLog.log("Moved \(moved) item(s) from \(legacy.path) to \(target.path)")
        }
    }

    private static func makeSessionFolderURL(for session: ScreenshotSession) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return rootFolder.appendingPathComponent(f.string(from: session.startedAt), isDirectory: true)
    }

    private static func restoreSession() -> (session: ScreenshotSession, folder: URL)? {
        guard let path = UserDefaults.standard.string(forKey: currentSessionKey) else { return nil }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        guard let session = ScreenshotSessionExporter.loadSession(in: folder) else {
            ScreenshotNotesLog.error("Could not restore session from \(folder.path) – starting a new one")
            UserDefaults.standard.removeObject(forKey: currentSessionKey)
            return nil
        }
        // Drop captures whose image vanished
        var cleaned = session
        cleaned.captures.removeAll { capture in
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent(capture.imageFileName).path)
        }
        return (cleaned, folder)
    }

    private func ensureSessionFolder() throws {
        if !FileManager.default.fileExists(atPath: sessionFolder.path) {
            if session.captures.isEmpty {
                // Name the folder after the moment the first screenshot is taken,
                // not after the moment the previous session was finished.
                let fresh = ScreenshotSession(title: session.title, task: session.task)
                session = fresh
                sessionFolder = Self.makeSessionFolderURL(for: fresh)
            }
            try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
            logger.info("Created session folder \(self.sessionFolder.path)")
        }
        UserDefaults.standard.set(sessionFolder.path, forKey: Self.currentSessionKey)
    }

    private func persist() {
        do {
            try ensureSessionFolder()
            try ScreenshotSessionExporter.saveSession(session, in: sessionFolder)
            try ScreenshotSessionExporter.writeNotes(for: session, folder: sessionFolder)
        } catch {
            logger.error("Failed to persist session: \(error.localizedDescription)")
            ScreenshotNotesLog.error("Failed to persist session: \(error.localizedDescription)")
        }
    }

    // MARK: - Paths

    var notesURL: URL {
        ScreenshotSessionExporter.notesURL(in: sessionFolder)
    }

    var pdfURL: URL {
        ScreenshotSessionExporter.pdfURL(in: sessionFolder)
    }

    /// ZIP next to the session folder: <root>/<session-name>.zip
    var zipURL: URL {
        ScreenshotSessionExporter.zipURL(for: sessionFolder)
    }

    func imageURL(for capture: ScreenshotCapture) -> URL {
        sessionFolder.appendingPathComponent(capture.imageFileName)
    }

    func capture(withID id: UUID) -> ScreenshotCapture? {
        session.captures.first { $0.id == id }
    }

    // MARK: - Captures

    /// Stores a fresh capture on disk and adds it to the session.
    func addCapture(_ result: CaptureResult) throws -> ScreenshotCapture {
        try ensureSessionFolder()

        let index = session.nextIndex
        let format = ScreenshotImageRenderer.Format.stored
        let fileName = String(format: "%03d.%@", index, format.fileExtension)
        let url = sessionFolder.appendingPathComponent(fileName)

        // Downscale Retina captures and store as JPEG – keeps PDFs/ZIPs small
        guard let decoded = ScreenshotImageRenderer.cgImage(fromPNG: result.pngData) else {
            throw ScreenshotNotesError.writeFailed("could not decode screenshot")
        }
        let stored = ScreenshotImageRenderer.downscaled(decoded, maxDimension: ScreenshotImageRenderer.storedMaxDimension)
        guard let encoded = ScreenshotImageRenderer.data(from: stored, format: format) else {
            throw ScreenshotNotesError.writeFailed("could not encode screenshot")
        }
        do {
            try encoded.write(to: url, options: .atomic)
        } catch {
            throw ScreenshotNotesError.writeFailed(error.localizedDescription)
        }
        ScreenshotNotesLog.log("Stored screenshot \(stored.width)x\(stored.height) as \(format.fileExtension) (\(encoded.count / 1024) KB, source \(decoded.width)x\(decoded.height))")

        let capture = ScreenshotCapture(
            index: index,
            appName: result.info.appName,
            windowTitle: result.info.windowTitle,
            pageURL: result.info.pageURL,
            imageFileName: fileName,
            pixelWidth: stored.width,
            pixelHeight: stored.height
        )
        cgImageCache[capture.id] = stored

        session.captures.append(capture)
        // Content changed after an export: the session is "in progress" again
        session.finishedAt = nil
        persist()
        logger.info("Added capture #\(index) (\(capture.pixelWidth)x\(capture.pixelHeight))")
        ScreenshotNotesLog.log("Stored capture #\(index) as \(url.path)")
        return capture
    }

    /// Saves edited notes/regions and re-renders derived images.
    func update(_ capture: ScreenshotCapture) {
        guard let idx = session.captures.firstIndex(where: { $0.id == capture.id }) else { return }
        var updated = capture
        renderDerivedImages(for: &updated)
        if session.captures[idx] != updated {
            session.finishedAt = nil
        }
        session.captures[idx] = updated
        persist()
    }

    func delete(_ capture: ScreenshotCapture) {
        guard session.captures.contains(where: { $0.id == capture.id }) else { return }
        removeFiles(for: capture)
        session.captures.removeAll { $0.id == capture.id }
        thumbnailCache[capture.id] = nil
        cgImageCache[capture.id] = nil
        // Close the gap: remaining captures (and their files) get indices 1…n again
        session.captures = ScreenshotSessionExporter.renumber(session.captures, folder: sessionFolder)
        session.finishedAt = nil
        persist()
        logger.info("Deleted capture #\(capture.index)")
        ScreenshotNotesLog.log("Deleted capture #\(capture.index), \(session.captures.count) left (renumbered)")
    }

    func setSessionTitle(_ title: String) {
        guard session.title != title else { return }
        session.title = title
        persist()
    }

    func setSessionTask(_ task: String) {
        guard session.task != task else { return }
        session.task = task
        persist()
    }

    /// Makes sure notes.md on disk reflects the current state.
    func flush() {
        persist()
    }

    // MARK: - Images

    func cgImage(for capture: ScreenshotCapture) -> CGImage? {
        if let cached = cgImageCache[capture.id] { return cached }
        guard let data = try? Data(contentsOf: imageURL(for: capture)),
              let cg = ScreenshotImageRenderer.cgImage(fromPNG: data) else { return nil }
        cgImageCache[capture.id] = cg
        return cg
    }

    func image(for capture: ScreenshotCapture) -> NSImage? {
        guard let cg = cgImage(for: capture) else { return nil }
        // Use pixel size as point size: the canvas scales it anyway
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    func thumbnail(for capture: ScreenshotCapture) -> NSImage? {
        if let cached = thumbnailCache[capture.id] { return cached }
        guard let full = image(for: capture) else { return nil }
        let thumb = ScreenshotImageRenderer.thumbnail(from: full, maxDimension: 160)
        thumbnailCache[capture.id] = thumb
        return thumb
    }

    private func renderDerivedImages(for capture: inout ScreenshotCapture) {
        // Remove stale region crops first (numbering may have shifted)
        removeRegionCrops(for: capture)

        guard !capture.regions.isEmpty, let cg = cgImage(for: capture) else {
            if let annotated = capture.annotatedFileName {
                try? FileManager.default.removeItem(at: sessionFolder.appendingPathComponent(annotated))
            }
            capture.annotatedFileName = nil
            return
        }

        let format = ScreenshotImageRenderer.Format.forFileName(capture.imageFileName)
        let annotatedName = capture.annotatedFileNameCandidate
        if let data = ScreenshotImageRenderer.annotatedImage(original: cg, regions: capture.regions, format: format) {
            do {
                try data.write(to: sessionFolder.appendingPathComponent(annotatedName), options: .atomic)
                capture.annotatedFileName = annotatedName
            } catch {
                logger.error("Failed to write annotated image: \(error.localizedDescription)")
                capture.annotatedFileName = nil
            }
        }

        for (offset, region) in capture.regions.enumerated() {
            guard let data = ScreenshotImageRenderer.cropImage(original: cg, region: region, format: format) else { continue }
            let name = capture.regionFileName(number: offset + 1)
            do {
                try data.write(to: sessionFolder.appendingPathComponent(name), options: .atomic)
            } catch {
                logger.error("Failed to write region crop \(name): \(error.localizedDescription)")
            }
        }
    }

    private func removeRegionCrops(for capture: ScreenshotCapture) {
        let prefix = String(format: "%03d-region-", capture.index)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: sessionFolder.path) else { return }
        for name in contents where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: sessionFolder.appendingPathComponent(name))
        }
    }

    private func removeFiles(for capture: ScreenshotCapture) {
        try? FileManager.default.removeItem(at: imageURL(for: capture))
        if let annotated = capture.annotatedFileName {
            try? FileManager.default.removeItem(at: sessionFolder.appendingPathComponent(annotated))
        }
        removeRegionCrops(for: capture)
    }

    // MARK: - Finishing

    /// Current markdown (absolute image paths), ready to paste into an agent prompt.
    var markdownForAgent: String {
        ScreenshotSessionExporter.markdown(for: session, folder: sessionFolder)
    }

    /// Copies the full markdown to the clipboard so it can be pasted straight
    /// into an agent conversation. The agent finds file and folder paths inside.
    func copyMarkdownToClipboard() {
        ScreenshotSessionExporter.copyMarkdownToClipboard(for: session, folder: sessionFolder)
    }

    /// Renders the whole session into one PDF (images embedded) at `url`.
    /// Defaults to notes.pdf inside the session folder.
    @discardableResult
    func writePDF(to url: URL? = nil) throws -> URL {
        try ScreenshotSessionExporter.writePDF(for: session, folder: sessionFolder, to: url)
    }

    /// Packs the session into one ZIP: notes.md (relative paths), all images and
    /// notes.pdf. Writes to `url` or `zipURL`. Returns the ZIP location.
    @discardableResult
    func writeZip(to url: URL? = nil) throws -> URL {
        try ScreenshotSessionExporter.writeZip(for: session, folder: sessionFolder, to: url)
    }

    /// Files that belong in ZIPs / VM copies: images and the PDF (not session.json / previews).
    static func isSessionAsset(_ name: String) -> Bool {
        ScreenshotSessionExporter.isSessionAsset(name)
    }

    /// Copies images + PDF into a temp folder named like the session and writes a
    /// notes.md with relative paths next to them. Caller removes the parent dir.
    func stagePortableCopy() throws -> URL {
        try ScreenshotSessionExporter.stagePortableCopy(for: session, folder: sessionFolder)
    }

    /// Puts the hand-off on the clipboard. With a file this is the file only
    /// (so ⌘V attaches the ZIP/PDF instead of pasting text); without a file the
    /// markdown text is copied.
    func copyHandoffToClipboard(fileURL: URL?) {
        if let fileURL {
            ScreenshotSessionExporter.copyToClipboard(fileURL: fileURL)
        } else {
            copyMarkdownToClipboard()
        }
    }

    /// Writes notes.md, notes.pdf and the session ZIP, puts the chosen hand-off
    /// (ZIP / PDF / markdown text) on the clipboard, reveals the files in Finder
    /// and starts a new empty session. The finished session stays on disk and
    /// shows up in the history, where it can be exported again. Returns the
    /// hand-off file URL (or notes.md for the markdown-only format).
    @discardableResult
    func finishSession(revealInFinder: Bool = true) throws -> URL {
        guard !session.captures.isEmpty else {
            throw ScreenshotNotesError.emptySession
        }

        session.finishedAt = Date()
        persist()
        let finishedNotes = notesURL

        var pdf: URL?
        do {
            pdf = try writePDF()
        } catch {
            logger.error("PDF export failed: \(error.localizedDescription)")
            ScreenshotNotesLog.error("PDF export failed: \(error.localizedDescription)")
        }

        var zip: URL?
        do {
            zip = try writeZip()
        } catch {
            logger.error("ZIP export failed: \(error.localizedDescription)")
            ScreenshotNotesLog.error("ZIP export failed: \(error.localizedDescription)")
        }

        let format = HandoffFormat.current
        let handoffFile: URL?
        switch format {
        case .zip: handoffFile = zip ?? pdf
        case .pdf: handoffFile = pdf ?? zip
        case .markdown: handoffFile = nil
        }
        copyHandoffToClipboard(fileURL: handoffFile)

        if revealInFinder {
            // Reveal the hand-off file itself; otherwise the notes
            NSWorkspace.shared.activateFileViewerSelecting([handoffFile ?? finishedNotes])
        }

        logger.info("Finished session with \(self.session.captures.count) captures: \(finishedNotes.path)")
        ScreenshotNotesLog.log("Finished session: notes=\(finishedNotes.path) pdf=\(pdf?.path ?? "-") zip=\(zip?.path ?? "-") handoff=\(format.rawValue)")
        startNewSession()
        ScreenshotHistoryStore.shared.refreshAndPrune()
        return handoffFile ?? finishedNotes
    }

    /// Discards the in-memory session state and begins a new one. Files of the
    /// old session stay on disk (and appear in the history).
    func startNewSession() {
        let fresh = ScreenshotSession()
        session = fresh
        sessionFolder = Self.makeSessionFolderURL(for: fresh)
        thumbnailCache.removeAll()
        cgImageCache.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.currentSessionKey)
        ScreenshotHistoryStore.shared.refresh()
    }

    /// Makes an archived session the current one again so it can be edited,
    /// extended and exported with the normal flow. Whatever was open before
    /// stays on disk and moves to the history.
    func adopt(session archived: ScreenshotSession, folder: URL) {
        guard archived.id != session.id else { return }
        if !session.captures.isEmpty {
            persist()
        }
        session = archived
        sessionFolder = folder
        thumbnailCache.removeAll()
        cgImageCache.removeAll()
        UserDefaults.standard.set(folder.path, forKey: Self.currentSessionKey)
        ScreenshotNotesLog.log("Reopened session \(folder.lastPathComponent) with \(archived.captures.count) captures")
        ScreenshotHistoryStore.shared.refresh()
    }

    func revealSessionFolder() {
        if FileManager.default.fileExists(atPath: notesURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([notesURL])
        } else if FileManager.default.fileExists(atPath: sessionFolder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([sessionFolder])
        } else {
            try? FileManager.default.createDirectory(at: Self.rootFolder, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([Self.rootFolder])
        }
    }
}
