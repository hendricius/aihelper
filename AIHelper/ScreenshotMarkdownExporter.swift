import Foundation

/// Generates the notes.md handed to the agent. Pure function of the session,
/// so it can be regenerated after every change.
enum ScreenshotMarkdownExporter {

    enum PathStyle {
        /// Absolute paths into the session folder – for pasting the text into a local agent.
        case absolute
        /// Paths relative to notes.md – for shipping the folder as a ZIP.
        case relative
    }

    /// - Parameters:
    ///   - folder: session folder on disk.
    ///   - pathStyle: how image references are written (see `PathStyle`).
    static func markdown(for session: ScreenshotSession, folder: URL, pathStyle: PathStyle = .absolute) -> String {
        var lines: [String] = []

        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("# \(title.isEmpty ? "Screenshot Notes" : title)")
        lines.append("")
        lines.append("- Session started: \(dateTime(session.startedAt))")
        lines.append("- Screenshots: \(session.captures.count)")
        switch pathStyle {
        case .absolute:
            lines.append("- Folder: `\(folder.path)`")
            lines.append("- This file: `\(folder.appendingPathComponent(ScreenshotNotesStore.notesFileName).path)`")
        case .relative:
            lines.append("- Original folder on my Mac: `\(folder.path)`")
            lines.append("- Image paths below are relative to this file (all files are in the same folder/ZIP).")
        }
        lines.append("")
        let task = session.task.trimmingCharacters(in: .whitespacesAndNewlines)
        if !task.isEmpty {
            lines.append("## Task for the agent")
            lines.append("")
            lines.append(task)
            lines.append("")
        }
        lines.append("## How to read this file")
        lines.append("")
        lines.append("These are screenshots of web pages/windows I took while browsing, with my comments. For each screenshot:")
        lines.append("")
        lines.append("- **Screenshot** is the untouched capture (JPEG), **Annotated** is the same image with red numbered markers drawn onto it.")
        lines.append("- Every numbered marker corresponds to an **Area N** entry below the image; the note there is my comment about exactly that part of the page.")
        lines.append("- **Crop** is a cut-out of just that marked area, in case you want to look at the detail without the rest of the page.")
        lines.append("- Positions are pixel coordinates in the original image (origin top-left) plus percentages of width/height.")
        lines.append("- Open the images to see what I am referring to.")
        lines.append("")

        let sorted = session.captures.sorted { $0.index < $1.index }
        for capture in sorted {
            lines.append(contentsOf: section(for: capture, folder: folder, pathStyle: pathStyle))
            lines.append("")
        }

        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    static func section(for capture: ScreenshotCapture, folder: URL, pathStyle: PathStyle = .absolute) -> [String] {
        var lines: [String] = []
        func abs(_ name: String) -> String {
            switch pathStyle {
            case .absolute: return folder.appendingPathComponent(name).path
            case .relative: return name
            }
        }
        lines.append("## \(capture.index). \(escapeHeading(capture.displayTitle))")
        lines.append("")

        if let url = capture.pageURL, !url.isEmpty {
            lines.append("- URL: <\(url)>")
        }
        if let app = capture.appName, !app.isEmpty {
            lines.append("- App: \(app)")
        }
        lines.append("- Captured: \(dateTime(capture.date))")
        lines.append("- Size: \(capture.pixelWidth)×\(capture.pixelHeight) px")
        lines.append("- Screenshot: `\(abs(capture.imageFileName))`")
        if let annotated = capture.annotatedFileName {
            lines.append("- Annotated: `\(abs(annotated))`")
        }
        lines.append("")

        let primaryImage = capture.annotatedFileName ?? capture.imageFileName
        lines.append("![Screenshot \(capture.index)](\(abs(primaryImage)))")
        lines.append("")

        let general = capture.generalNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !general.isEmpty {
            lines.append("### Notes")
            lines.append("")
            lines.append(general)
            lines.append("")
        }

        if !capture.regions.isEmpty {
            lines.append("### Marked areas")
            lines.append("")
            for (offset, region) in capture.regions.enumerated() {
                let number = offset + 1
                let px = region.pixelRect(in: capture.pixelSize)
                let note = region.note.trimmingCharacters(in: .whitespacesAndNewlines)
                let coords = "x=\(Int(px.origin.x)), y=\(Int(px.origin.y)), w=\(Int(px.width)), h=\(Int(px.height))"
                let percent = String(
                    format: "%.0f%%–%.0f%% horizontal, %.0f%%–%.0f%% vertical",
                    region.x * 100, (region.x + region.width) * 100,
                    region.y * 100, (region.y + region.height) * 100
                )
                lines.append("#### Area \(number)")
                lines.append("")
                lines.append("- Position: \(coords) px (\(percent))")
                lines.append("- Crop: `\(abs(capture.regionFileName(number: number)))`")
                lines.append("")
                lines.append(note.isEmpty ? "_(no note)_" : note)
                lines.append("")
            }
        }

        while lines.last == "" { lines.removeLast() }
        return lines
    }

    // MARK: - Helpers

    private static func escapeHeading(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func dateTime(_ date: Date) -> String {
        formatter.string(from: date)
    }
}
