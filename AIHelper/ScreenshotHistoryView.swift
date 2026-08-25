import SwiftUI
import AppKit

// MARK: - History window

/// The last few screenshot sessions with everything needed to get them back:
/// copy the PDF/ZIP/Markdown again, send them to an agent, reopen or delete.
struct ScreenshotHistoryView: View {
    @ObservedObject private var history = ScreenshotHistoryStore.shared
    @ObservedObject private var store = ScreenshotNotesStore.shared
    @AppStorage(ScreenshotHistoryStore.keepLimitKey) private var keepLimit = ScreenshotHistoryStore.defaultKeepLimit
    @State private var pendingDelete: ScreenshotSessionEntry?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.session.captures.isEmpty && history.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !store.session.captures.isEmpty {
                            currentSessionRow
                            Divider().padding(.leading, 16)
                        }
                        ForEach(history.entries) { entry in
                            ScreenshotHistoryRow(
                                entry: entry,
                                thumbnail: history.thumbnails[entry.id],
                                isBusy: history.busyEntryID == entry.id,
                                onDelete: { pendingDelete = entry }
                            )
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 360)
        .onAppear { history.refresh() }
        .confirmationDialog(
            "Delete “\(pendingDelete?.title ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let entry = pendingDelete { history.delete(entry) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The session folder with its screenshots, notes, PDF and ZIP is moved to the Trash.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Screenshot Notes History")
                    .font(.headline)
                Text("Every exported session stays here until it drops off the end of the list. Copy its PDF again, send it to an agent, or reopen it to add more.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                ScreenshotAnnotationWindowController.shared.captureAndAnnotate()
            } label: {
                Label("New Screenshot", systemImage: "camera.viewfinder")
            }
            .help("Capture the frontmost window (\(ShortcutConfig.annotateScreenshot.displayString))")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var currentSessionRow: some View {
        let count = store.session.captures.count
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.12))
                if let first = store.session.captures.first, let thumb = store.thumbnail(for: first) {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(width: 96, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("In progress")
                        .font(.subheadline.weight(.semibold))
                }
                Text(store.session.displayTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(count) screenshot\(count == 1 ? "" : "s") · not exported yet · \(ShortcutConfig.finishScreenshotSession.displayString) exports to clipboard")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                ScreenshotAnnotationWindowController.shared.openReview()
            } label: {
                Label("Review & Export", systemImage: "paperplane")
            }
            .buttonStyle(.borderedProminent)
            Button("Open Editor") {
                ScreenshotAnnotationWindowController.shared.showSession()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.05))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No screenshot sessions yet")
                .font(.headline)
            Text("Press \(ShortcutConfig.annotateScreenshot.displayString) in any window to take a screenshot and add notes. After \(ShortcutConfig.finishScreenshotSession.displayString) the session shows up here.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Keep the last")
                .font(.caption)
            Stepper(value: $keepLimit, in: ScreenshotHistoryStore.keepLimitRange) {
                Text("\(keepLimit) session\(keepLimit == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 70, alignment: .leading)
            }
            .onChange(of: keepLimit) { _, _ in history.refreshAndPrune() }
            Text("· older ones are deleted automatically when a new one is exported")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("Open Folder") {
                history.revealRootFolder()
            }
            .help(ScreenshotNotesStore.rootFolder.path)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Row

struct ScreenshotHistoryRow: View {
    let entry: ScreenshotSessionEntry
    let thumbnail: NSImage?
    let isBusy: Bool
    let onDelete: () -> Void

    private var history: ScreenshotHistoryStore { ScreenshotHistoryStore.shared }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.15))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "photo")
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 96, height: 64)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.gray.opacity(0.25), lineWidth: 1)
            )
            .onTapGesture { history.reveal(entry) }
            .help("Show in Finder")

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.pageList)
                Text("\(Self.dateFormatter.string(from: entry.date)) · \(entry.summary) · \(entry.formattedSize)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 5) {
                    Image(systemName: entry.isExported ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundColor(entry.isExported ? .green : .orange)
                        .font(.caption)
                    Text(entry.isExported ? "Exported" : "Not exported – reopen to finish")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()

            if isBusy {
                ProgressView().controlSize(.small)
            }

            Button {
                history.copyPDF(entry)
            } label: {
                Label("Copy PDF", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy)
            .help("Put notes.pdf on the clipboard – ⌘V attaches it in claude.ai, Mail, Finder…")

            Menu {
                Button { history.copyZip(entry) } label: {
                    Label("Copy ZIP (notes.md + images + PDF)", systemImage: "doc.zipper")
                }
                Button { history.copyMarkdown(entry) } label: {
                    Label("Copy Markdown text", systemImage: "text.alignleft")
                }
                Divider()
                Button { history.sendToLocalClaudeCode(entry) } label: {
                    Label("Send to Claude Code (this Mac)", systemImage: "terminal")
                }
                Button { history.sendToVM(entry) } label: {
                    Label("Send to VM of current iTerm tab", systemImage: "server.rack")
                }
                Divider()
                Button { history.savePDFAs(entry, parent: NSApp.keyWindow) } label: {
                    Label("Save PDF As…", systemImage: "square.and.arrow.down")
                }
                Button { history.saveZipAs(entry, parent: NSApp.keyWindow) } label: {
                    Label("Save ZIP As…", systemImage: "square.and.arrow.down")
                }
                Divider()
                Button { history.reopen(entry) } label: {
                    Label("Reopen & Edit", systemImage: "pencil")
                }
                Button { history.reveal(entry) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("Move to Trash", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isBusy)
            .help("More: ZIP, Markdown, send to agent, reopen, delete")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()
}

// MARK: - Compact block for the menu bar popover

/// Two lines at most: the session being collected and the last export, each
/// with its most useful action. "History" opens the full window.
struct ScreenshotNotesInlineView: View {
    @ObservedObject private var history = ScreenshotHistoryStore.shared
    @ObservedObject private var store = ScreenshotNotesStore.shared

    /// True when the block has something to show.
    static func isVisible(store: ScreenshotNotesStore, history: ScreenshotHistoryStore) -> Bool {
        !store.session.captures.isEmpty || !history.entries.isEmpty
    }

    /// Height the popover must reserve for this block.
    static func height(store: ScreenshotNotesStore, history: ScreenshotHistoryStore) -> CGFloat {
        guard isVisible(store: store, history: history) else { return 0 }
        var h: CGFloat = 34   // divider + header
        if !store.session.captures.isEmpty { h += 30 }
        if history.latestExported != nil { h += 36 }
        return h
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Screenshot Notes", systemImage: "camera.viewfinder")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.purple)
                Spacer()
                Button {
                    ScreenshotHistoryWindowController.shared.showWindow()
                } label: {
                    HStack(spacing: 3) {
                        Text("History")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .help("All recent sessions: copy PDF/ZIP again, send to an agent, reopen")
            }

            if !store.session.captures.isEmpty {
                let count = store.session.captures.count
                HStack(spacing: 8) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("Collecting: \(count) screenshot\(count == 1 ? "" : "s")")
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Button("Review & Export") {
                        ScreenshotAnnotationWindowController.shared.openReview()
                    }
                    .font(.caption)
                    .controlSize(.small)
                    .help("Check everything, then export with ↩ (\(ShortcutConfig.reviewScreenshotSession.displayString); \(ShortcutConfig.finishScreenshotSession.displayString) exports right away)")
                }
            }

            if let latest = history.latestExported {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.2))
                        if let thumb = history.thumbnails[latest.id] {
                            Image(nsImage: thumb)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    .frame(width: 40, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(latest.title)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("Last export · \(ScreenshotHistoryRow.dateFormatter.string(from: latest.date)) · \(latest.summary)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button("Copy PDF") {
                        history.copyPDF(latest)
                    }
                    .font(.caption)
                    .controlSize(.small)
                    .help("Put the PDF of the last exported session on the clipboard again")
                }
            }
        }
    }
}
