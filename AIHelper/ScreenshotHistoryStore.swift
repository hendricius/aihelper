import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "ScreenshotHistory")

/// One archived session: its folder on disk plus the decoded `session.json`.
struct ScreenshotSessionEntry: Identifiable, Equatable {
    let session: ScreenshotSession
    let folder: URL
    let byteSize: Int64

    var id: UUID { session.id }
    var date: Date { session.lastActivity }
    var captureCount: Int { session.captures.count }
    var title: String { session.displayTitle }
    var isExported: Bool { session.finishedAt != nil }
    var notesURL: URL { ScreenshotSessionExporter.notesURL(in: folder) }
    var pdfURL: URL { ScreenshotSessionExporter.pdfURL(in: folder) }
    var zipURL: URL { ScreenshotSessionExporter.zipURL(for: folder) }

    /// Number of marked areas across all screenshots.
    var areaCount: Int { session.captures.reduce(0) { $0 + $1.regions.count } }

    /// "3 screenshots · 5 areas"
    var summary: String {
        var parts = ["\(captureCount) screenshot\(captureCount == 1 ? "" : "s")"]
        if areaCount > 0 { parts.append("\(areaCount) area\(areaCount == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    /// Page titles / URLs of the captures, deduplicated, for tooltips.
    var pageList: String {
        var seen = Set<String>()
        return session.captures.map(\.displayTitle).filter { seen.insert($0).inserted }.joined(separator: "\n")
    }
}

/// Lists finished (and parked) sessions in the output folder and keeps only
/// the most recent ones. Every entry can be exported again or reopened.
@MainActor
final class ScreenshotHistoryStore: ObservableObject {
    static let shared = ScreenshotHistoryStore()

    /// How many sessions besides the current one are kept – UserDefaults key.
    static let keepLimitKey = "screenshotNotes.historyLimit"
    static let defaultKeepLimit = 5
    static let keepLimitRange = 1...20

    @Published private(set) var entries: [ScreenshotSessionEntry] = []
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    @Published private(set) var busyEntryID: UUID?

    private var thumbnailTasks: Set<UUID> = []

    static var keepLimit: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: keepLimitKey)
            return stored == 0 ? defaultKeepLimit : min(max(stored, keepLimitRange.lowerBound), keepLimitRange.upperBound)
        }
        set {
            UserDefaults.standard.set(min(max(newValue, keepLimitRange.lowerBound), keepLimitRange.upperBound), forKey: keepLimitKey)
        }
    }

    private init() {
        refresh()
    }

    /// Most recent exported session – the one the user most likely wants back.
    var latestExported: ScreenshotSessionEntry? {
        entries.first { $0.isExported }
    }

    // MARK: - Scanning

    /// Re-reads the output folder. Sessions without screenshots are removed
    /// right away (they are left behind by cancelled captures).
    func refresh() {
        let fm = FileManager.default
        let root = ScreenshotNotesStore.rootFolder
        let current = ScreenshotNotesStore.shared.sessionFolder.standardizedFileURL
        var found: [ScreenshotSessionEntry] = []

        if let names = try? fm.contentsOfDirectory(atPath: root.path) {
            for name in names where !name.hasPrefix(".") {
                let folder = root.appendingPathComponent(name, isDirectory: true)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }
                guard let session = ScreenshotSessionExporter.loadSession(in: folder) else { continue }
                if folder.standardizedFileURL == current { continue }

                // Only captures whose image still exists count
                var cleaned = session
                cleaned.captures.removeAll { !fm.fileExists(atPath: folder.appendingPathComponent($0.imageFileName).path) }
                if cleaned.captures.isEmpty {
                    removeFiles(of: folder)
                    continue
                }
                found.append(ScreenshotSessionEntry(session: cleaned, folder: folder, byteSize: ScreenshotSessionExporter.byteSize(of: folder)))
            }
        }

        found.sort { $0.date > $1.date }
        if found != entries {
            entries = found
        }
        let ids = Set(found.map(\.id))
        thumbnails = thumbnails.filter { ids.contains($0.key) }
        for entry in found where thumbnails[entry.id] == nil {
            loadThumbnail(for: entry)
        }
    }

    /// Deletes everything beyond the configured limit (oldest first) plus ZIPs
    /// whose session folder is gone.
    func prune() {
        let limit = Self.keepLimit
        guard entries.count > limit else {
            removeOrphanZips()
            return
        }
        let victims = entries.suffix(from: limit)
        for victim in victims {
            removeFiles(of: victim.folder)
            ScreenshotNotesLog.log("History: removed old session \(victim.folder.lastPathComponent) (keeping \(limit))")
        }
        entries = Array(entries.prefix(limit))
        removeOrphanZips()
    }

    func refreshAndPrune() {
        refresh()
        prune()
    }

    // MARK: - Actions

    /// Puts notes.pdf of the session on the clipboard, rendering it if needed.
    func copyPDF(_ entry: ScreenshotSessionEntry) {
        perform(entry, "PDF") {
            let pdf = try ScreenshotSessionExporter.ensurePDF(for: entry.session, folder: entry.folder)
            ScreenshotSessionExporter.copyToClipboard(fileURL: pdf)
            return "PDF in clipboard – ⌘V to hand it to your agent (\(pdf.lastPathComponent))"
        }
    }

    /// Puts the session ZIP on the clipboard, building it if needed.
    func copyZip(_ entry: ScreenshotSessionEntry) {
        perform(entry, "ZIP") {
            let zip = try ScreenshotSessionExporter.ensureZip(for: entry.session, folder: entry.folder)
            ScreenshotSessionExporter.copyToClipboard(fileURL: zip)
            return "ZIP in clipboard – ⌘V to hand it to your agent (\(zip.lastPathComponent))"
        }
    }

    func copyMarkdown(_ entry: ScreenshotSessionEntry) {
        ScreenshotSessionExporter.copyMarkdownToClipboard(for: entry.session, folder: entry.folder)
        StatusOverlay.shared.showBrief(message: "Markdown in clipboard – ⌘V to paste it into your agent")
    }

    /// Asks where to save a copy of the PDF.
    func savePDFAs(_ entry: ScreenshotSessionEntry, parent: NSWindow?) {
        let panel = NSSavePanel()
        panel.title = "Save Screenshot Notes as PDF"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "screenshot-notes-\(entry.folder.lastPathComponent).pdf"
        runPanel(panel, parent: parent) { url in
            self.perform(entry, "PDF") {
                try ScreenshotSessionExporter.writePDF(for: entry.session, folder: entry.folder, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return "PDF saved"
            }
        }
    }

    /// Asks where to save a copy of the ZIP.
    func saveZipAs(_ entry: ScreenshotSessionEntry, parent: NSWindow?) {
        let panel = NSSavePanel()
        panel.title = "Save Screenshot Notes as ZIP"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = entry.zipURL.lastPathComponent
        runPanel(panel, parent: parent) { url in
            self.perform(entry, "ZIP") {
                _ = try ScreenshotSessionExporter.ensurePDF(for: entry.session, folder: entry.folder)
                try ScreenshotSessionExporter.writeZip(for: entry.session, folder: entry.folder, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return "ZIP saved"
            }
        }
    }

    func sendToLocalClaudeCode(_ entry: ScreenshotSessionEntry) {
        busyEntryID = entry.id
        Task { @MainActor in
            defer { busyEntryID = nil }
            do {
                try await AgentHandoffService.sendToLocalClaudeCode(session: entry.session, folder: entry.folder)
                StatusOverlay.shared.showBrief(message: "Claude Code started in the session folder")
            } catch {
                StatusOverlay.shared.showBrief(message: error.localizedDescription)
            }
        }
    }

    func sendToVM(_ entry: ScreenshotSessionEntry) {
        busyEntryID = entry.id
        StatusOverlay.shared.showBrief(message: "Uploading session to VM…")
        Task { @MainActor in
            defer { busyEntryID = nil }
            do {
                let host = try await AgentHandoffService.sendToVM(session: entry.session, folder: entry.folder)
                StatusOverlay.shared.showBrief(message: "Sent to \(host) – prompt typed in iTerm")
            } catch {
                StatusOverlay.shared.showBrief(message: error.localizedDescription)
            }
        }
    }

    /// Makes the session current again and opens it in the editor.
    func reopen(_ entry: ScreenshotSessionEntry) {
        guard let session = ScreenshotSessionExporter.loadSession(in: entry.folder) else {
            StatusOverlay.shared.showBrief(message: "Session files are missing")
            refresh()
            return
        }
        let parked = ScreenshotNotesStore.shared.session.captures.count
        ScreenshotNotesStore.shared.adopt(session: session, folder: entry.folder)
        ScreenshotAnnotationWindowController.shared.showSession()
        if parked > 0 {
            StatusOverlay.shared.showBrief(message: "Session reopened – the \(parked) screenshot\(parked == 1 ? "" : "s") you were collecting moved to History")
        } else {
            StatusOverlay.shared.showBrief(message: "Session reopened – add screenshots or export again")
        }
    }

    func reveal(_ entry: ScreenshotSessionEntry) {
        let fm = FileManager.default
        let target = [entry.pdfURL, entry.notesURL, entry.folder].first { fm.fileExists(atPath: $0.path) } ?? entry.folder
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func revealRootFolder() {
        let root = ScreenshotNotesStore.rootFolder
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    /// Moves the session folder and its ZIP to the Trash.
    func delete(_ entry: ScreenshotSessionEntry) {
        let fm = FileManager.default
        for url in [entry.folder, entry.zipURL] where fm.fileExists(atPath: url.path) {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
            } catch {
                try? fm.removeItem(at: url)
            }
        }
        ScreenshotNotesLog.log("History: deleted session \(entry.folder.lastPathComponent)")
        refresh()
        StatusOverlay.shared.showBrief(message: "Session moved to Trash")
    }

    // MARK: - Helpers

    private func perform(_ entry: ScreenshotSessionEntry, _ what: String, _ work: () throws -> String) {
        busyEntryID = entry.id
        defer { busyEntryID = nil }
        do {
            let message = try work()
            StatusOverlay.shared.showBrief(message: message)
            refresh()
        } catch {
            ScreenshotNotesLog.error("History: \(what) for \(entry.folder.lastPathComponent) failed: \(error.localizedDescription)")
            StatusOverlay.shared.showBrief(message: error.localizedDescription)
        }
    }

    private func runPanel(_ panel: NSSavePanel, parent: NSWindow?, completion: @escaping (URL) -> Void) {
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
        if let parent, parent.isVisible {
            panel.beginSheetModal(for: parent, completionHandler: handler)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            handler(panel.runModal())
        }
    }

    private func removeFiles(of folder: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try? fm.removeItem(at: ScreenshotSessionExporter.zipURL(for: folder))
    }

    /// ZIPs in the root whose session folder no longer exists.
    private func removeOrphanZips() {
        let fm = FileManager.default
        let root = ScreenshotNotesStore.rootFolder
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.lowercased().hasSuffix(".zip") {
            let folderName = String(name.dropLast(4))
            let folder = root.appendingPathComponent(folderName, isDirectory: true)
            guard Self.looksLikeSessionName(folderName), !fm.fileExists(atPath: folder.path) else { continue }
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
    }

    /// "2026-08-21_12-36-55"
    private static func looksLikeSessionName(_ name: String) -> Bool {
        name.range(of: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    private func loadThumbnail(for entry: ScreenshotSessionEntry) {
        guard !thumbnailTasks.contains(entry.id), let first = entry.session.captures.first else { return }
        thumbnailTasks.insert(entry.id)
        let fileName = first.annotatedFileName ?? first.imageFileName
        let url = entry.folder.appendingPathComponent(fileName)
        let fallback = entry.folder.appendingPathComponent(first.imageFileName)
        let id = entry.id
        Task.detached(priority: .utility) {
            let data = (try? Data(contentsOf: url)) ?? (try? Data(contentsOf: fallback))
            guard let data, let cg = ScreenshotImageRenderer.cgImage(fromPNG: data) else { return }
            let small = ScreenshotImageRenderer.downscaled(cg, maxDimension: 320)
            let image = NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height))
            await MainActor.run {
                self.thumbnails[id] = image
                self.thumbnailTasks.remove(id)
            }
        }
    }
}
