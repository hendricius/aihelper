import Foundation
import CoreGraphics

/// A rectangular region inside a screenshot with a note attached.
/// Coordinates are normalized (0...1) relative to the image, origin top-left,
/// so they are independent of Retina scale and window size.
struct ScreenshotRegion: Identifiable, Codable, Equatable {
    let id: UUID
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var note: String

    init(id: UUID = UUID(), rect: CGRect, note: String = "") {
        self.id = id
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.width
        self.height = rect.height
        self.note = note
    }

    var normalizedRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// Rect in pixel coordinates (origin top-left) for an image of the given pixel size.
    func pixelRect(in pixelSize: CGSize) -> CGRect {
        CGRect(
            x: (x * pixelSize.width).rounded(),
            y: (y * pixelSize.height).rounded(),
            width: (width * pixelSize.width).rounded(),
            height: (height * pixelSize.height).rounded()
        )
    }
}

/// One captured page/window inside a session.
struct ScreenshotCapture: Identifiable, Codable, Equatable {
    let id: UUID
    /// 1-based position within the session, used for file names and headings.
    /// Renumbered (with file renames) when an earlier capture is removed.
    var index: Int
    let date: Date
    var appName: String?
    var windowTitle: String?
    var pageURL: String?
    /// File names are relative to the session folder.
    var imageFileName: String
    var annotatedFileName: String?
    let pixelWidth: Int
    let pixelHeight: Int
    var generalNote: String
    var regions: [ScreenshotRegion]

    init(
        id: UUID = UUID(),
        index: Int,
        date: Date = Date(),
        appName: String? = nil,
        windowTitle: String? = nil,
        pageURL: String? = nil,
        imageFileName: String,
        annotatedFileName: String? = nil,
        pixelWidth: Int,
        pixelHeight: Int,
        generalNote: String = "",
        regions: [ScreenshotRegion] = []
    ) {
        self.id = id
        self.index = index
        self.date = date
        self.appName = appName
        self.windowTitle = windowTitle
        self.pageURL = pageURL
        self.imageFileName = imageFileName
        self.annotatedFileName = annotatedFileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.generalNote = generalNote
        self.regions = regions
    }

    var pixelSize: CGSize {
        CGSize(width: pixelWidth, height: pixelHeight)
    }

    /// Extension of the stored screenshot ("png" for old sessions, "jpg" for new ones).
    var imageExtension: String {
        let ext = (imageFileName as NSString).pathExtension
        return ext.isEmpty ? "png" : ext
    }

    /// File name used for the cropped image of a region (1-based region number).
    func regionFileName(number: Int) -> String {
        String(format: "%03d-region-%d.%@", index, number, imageExtension)
    }

    var annotatedFileNameCandidate: String {
        String(format: "%03d-annotated.%@", index, imageExtension)
    }

    var displayTitle: String {
        if let title = windowTitle, !title.isEmpty { return title }
        if let url = pageURL, !url.isEmpty { return url }
        return "Screenshot \(index)"
    }

    var hasNotes: Bool {
        !generalNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || regions.contains { !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// A browsing session: a folder with screenshots, notes and a generated notes.md.
struct ScreenshotSession: Identifiable, Codable, Equatable {
    let id: UUID
    let startedAt: Date
    var title: String
    /// What the agent should do with the material – becomes the first section of notes.md.
    var task: String
    var captures: [ScreenshotCapture]
    /// Set when the session was exported (notes.pdf / ZIP written). Nil while it is still being collected.
    var finishedAt: Date?

    init(id: UUID = UUID(), startedAt: Date = Date(), title: String = "", task: String = "", captures: [ScreenshotCapture] = [], finishedAt: Date? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.title = title
        self.task = task
        self.captures = captures
        self.finishedAt = finishedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, title, task, captures, finishedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        task = try c.decodeIfPresent(String.self, forKey: .task) ?? ""
        captures = try c.decodeIfPresent([ScreenshotCapture].self, forKey: .captures) ?? []
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
    }

    var nextIndex: Int {
        (captures.map(\.index).max() ?? 0) + 1
    }

    /// When something last happened in this session: export, last capture, or start.
    var lastActivity: Date {
        if let finishedAt { return finishedAt }
        return captures.map(\.date).max() ?? startedAt
    }

    /// Session title, else the title of the first captured page, else a generic name.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let first = captures.first { return first.displayTitle }
        return "Screenshot session"
    }
}
