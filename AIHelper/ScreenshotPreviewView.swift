import SwiftUI
import AppKit
import WebKit
import PDFKit

/// "What the agent gets" – rendered notes, raw markdown or the PDF.
struct ScreenshotPreviewView: View {
    @ObservedObject var store: ScreenshotNotesStore

    enum Mode: String, CaseIterable, Identifiable {
        case rendered = "Rendered"
        case markdown = "Markdown"
        case pdf = "PDF"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .rendered
    @State private var pdfData: Data?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Spacer()
                Text(modeHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(10)
            Divider()

            switch mode {
            case .rendered:
                MarkdownWebView(
                    html: MiniMarkdownHTML.html(from: ScreenshotMarkdownExporter.markdown(for: store.session, folder: store.sessionFolder, pathStyle: .relative)),
                    folder: store.sessionFolder
                )
            case .markdown:
                ScrollView {
                    Text(store.markdownForAgent)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            case .pdf:
                PDFPreview(data: pdfData)
                    .onAppear(perform: renderPDF)
                    .onChange(of: store.session) { _, _ in renderPDF() }
            }
        }
    }

    private var modeHint: String {
        switch mode {
        case .rendered: return "How notes.md reads"
        case .markdown: return "Exactly what gets pasted / written to notes.md"
        case .pdf: return "notes.pdf as included in the ZIP"
        }
    }

    private func renderPDF() {
        pdfData = ScreenshotPDFExporter.pdfData(for: store.session, folder: store.sessionFolder)
    }
}

// MARK: - Web view

struct MarkdownWebView: NSViewRepresentable {
    let html: String
    /// Session folder: the HTML is written here as .preview.html so WebKit may
    /// load the PNGs next to it (loadHTMLString cannot read file:// images).
    let folder: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        let fileURL = folder.appendingPathComponent(".preview.html")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try html.write(to: fileURL, atomically: true, encoding: .utf8)
            view.loadFileURL(fileURL, allowingReadAccessTo: folder)
        } catch {
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastHTML: String?
    }
}

// MARK: - PDF view

struct PDFPreview: NSViewRepresentable {
    let data: Data?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .underPageBackgroundColor
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard let data else { return }
        if context.coordinator.lastData != data {
            context.coordinator.lastData = data
            view.document = PDFDocument(data: data)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastData: Data?
    }
}

// MARK: - Tiny markdown → HTML (covers exactly what the exporter emits)

enum MiniMarkdownHTML {
    static func html(from markdown: String) -> String {
        var body: [String] = []
        var inList = false
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                body.append("<p>\(paragraph.joined(separator: "<br>"))</p>")
                paragraph.removeAll()
            }
        }
        func closeList() {
            if inList { body.append("</ul>"); inList = false }
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph(); closeList()
                continue
            }
            if let (level, text) = heading(line) {
                flushParagraph(); closeList()
                body.append("<h\(level)>\(text)</h\(level)>")   // heading() already returns HTML
                continue
            }
            if line.hasPrefix("- ") {
                flushParagraph()
                if !inList { body.append("<ul>"); inList = true }
                body.append("<li>\(inline(String(line.dropFirst(2))))</li>")
                continue
            }
            if line.hasPrefix("![") , let img = image(line) {
                flushParagraph(); closeList()
                body.append(img)
                continue
            }
            closeList()
            paragraph.append(inline(line))
        }
        flushParagraph(); closeList()

        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
        :root { color-scheme: light dark; }
        body { font: 14px -apple-system, system-ui; line-height: 1.5; padding: 18px 24px; max-width: 860px; color: -apple-system-label; background: transparent; }
        h1 { font-size: 24px; margin: 0 0 8px; } h2 { font-size: 19px; margin: 26px 0 8px; border-top: 1px solid rgba(128,128,128,.3); padding-top: 14px; }
        h3 { font-size: 15px; margin: 18px 0 6px; } h4 { font-size: 14px; margin: 14px 0 4px; }
        h4 .badge { display:inline-block; min-width: 18px; padding: 0 5px; border-radius: 9px; background:#eb3333; color:#fff; font-size: 12px; text-align:center; margin-right: 6px; }
        img { max-width: 100%; border: 1px solid rgba(128,128,128,.35); border-radius: 4px; margin: 6px 0; }
        code { font: 12px ui-monospace, Menlo; background: rgba(128,128,128,.15); padding: 1px 4px; border-radius: 3px; word-break: break-all; }
        ul { padding-left: 20px; margin: 4px 0; } li { margin: 2px 0; } p { margin: 6px 0; } a { color: -apple-system-blue; }
        </style></head><body>\(body.joined(separator: "\n"))</body></html>
        """
    }

    private static func heading(_ line: String) -> (Int, String)? {
        for level in (1...4).reversed() {
            let prefix = String(repeating: "#", count: level) + " "
            if line.hasPrefix(prefix) {
                var text = String(line.dropFirst(prefix.count))
                if level == 4, text.hasPrefix("Area ") {
                    let number = text.dropFirst(5)
                    text = "<span class=\"badge\">\(escape(String(number)))</span>Area \(escape(String(number)))"
                    return (level, text)
                }
                return (level, escapeKeepingMarkup(text))
            }
        }
        return nil
    }

    private static func image(_ line: String) -> String? {
        guard let altEnd = line.firstIndex(of: "]"),
              line.index(after: altEnd) < line.endIndex,
              line[line.index(after: altEnd)] == "(",
              let close = line.lastIndex(of: ")") else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<altEnd])
        let path = String(line[line.index(altEnd, offsetBy: 2)..<close])
        let src: String
        if path.hasPrefix("/") {
            src = "file://" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
        } else {
            src = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        }
        return "<img src=\"\(src)\" alt=\"\(escape(alt))\">"
    }

    /// Escapes HTML, then applies inline markdown: `code`, **bold**, _italic_, <url>.
    private static func inline(_ text: String) -> String {
        escapeKeepingMarkup(text)
    }

    private static func escapeKeepingMarkup(_ text: String) -> String {
        var s = escape(text)
        s = replacePairs(in: s, token: "`", open: "<code>", close: "</code>")
        s = replacePairs(in: s, token: "**", open: "<strong>", close: "</strong>")
        // <https://…> autolinks (already escaped to &lt;…&gt;)
        if let regex = try? NSRegularExpression(pattern: "&lt;(https?://[^&]+)&gt;") {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "<a href=\"$1\">$1</a>")
        }
        if s.hasPrefix("_(") && s.hasSuffix(")_") {
            s = "<em>" + s.dropFirst().dropLast() + "</em>"
        }
        return s
    }

    private static func replacePairs(in text: String, token: String, open: String, close: String) -> String {
        var result = ""
        var remainder = Substring(text)
        var isOpen = false
        while let range = remainder.range(of: token) {
            result += remainder[..<range.lowerBound]
            result += isOpen ? close : open
            isOpen.toggle()
            remainder = remainder[range.upperBound...]
        }
        result += remainder
        if isOpen { result += close }
        return result
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
