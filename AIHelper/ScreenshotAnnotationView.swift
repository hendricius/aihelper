import SwiftUI
import AppKit

// MARK: - Model

/// Editing state for one capture. The window controller commits it back to
/// the store on save/close.
@MainActor
final class ScreenshotAnnotationModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case annotate = "Annotate"
        case preview = "Review & Export"
        var id: String { rawValue }
    }

    @Published var capture: ScreenshotCapture
    @Published var selectedRegionID: UUID?
    @Published var dictationTarget: DictationTarget?
    @Published var tab: Tab = .annotate
    /// Shown on the review tab after the user asked to export.
    @Published var isReviewingForExport = false
    @Published var isFinishingRecording = false

    let image: NSImage
    let dictation = DictationController()
    /// True until the user explicitly saved once; "Discard" removes new captures.
    private(set) var isNew: Bool
    private(set) var isDiscarded = false

    enum DictationTarget: Equatable, Hashable {
        case general
        case region(UUID)
    }

    init(capture: ScreenshotCapture, image: NSImage, isNew: Bool) {
        self.capture = capture
        self.image = image
        self.isNew = isNew
    }

    func markSaved() {
        isNew = false
    }

    func markDiscarded() {
        isDiscarded = true
        dictation.cancel()
    }

    // MARK: Regions

    @discardableResult
    func addRegion(_ rect: CGRect) -> ScreenshotRegion {
        let region = ScreenshotRegion(rect: rect)
        capture.regions.append(region)
        selectedRegionID = region.id
        return region
    }

    func removeRegion(_ id: UUID) {
        capture.regions.removeAll { $0.id == id }
        if selectedRegionID == id { selectedRegionID = nil }
        if dictationTarget == .region(id) {
            dictation.cancel()
            dictationTarget = nil
        }
    }

    func regionNumber(for id: UUID) -> Int? {
        capture.regions.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    // MARK: Dictation

    func toggleDictation(for target: DictationTarget) {
        if dictation.state == .recording, dictationTarget != target {
            // Switching targets while recording: stop the current one first
            return
        }
        dictationTarget = target
        dictation.toggle { [weak self] text in
            guard let self else { return }
            self.appendText(text, to: target)
            self.dictationTarget = nil
        }
        if dictation.state == .idle {
            dictationTarget = nil
        }
    }

    private func appendText(_ text: String, to target: DictationTarget) {
        switch target {
        case .general:
            capture.generalNote = joined(capture.generalNote, text)
        case .region(let id):
            guard let idx = capture.regions.firstIndex(where: { $0.id == id }) else { return }
            capture.regions[idx].note = joined(capture.regions[idx].note, text)
        }
    }

    private func joined(_ existing: String, _ addition: String) -> String {
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? addition : trimmed + " " + addition
    }
}

// MARK: - View

struct ScreenshotAnnotationView: View {
    @ObservedObject var model: ScreenshotAnnotationModel
    @ObservedObject private var store = ScreenshotNotesStore.shared

    let onSave: () -> Void
    let onDiscard: () -> Void
    let onFinish: () -> Void
    let onCopyMarkdown: () -> Void
    let onExportPDF: () -> Void
    let onExportZip: () -> Void
    let onSendLocal: () -> Void
    let onSendVM: () -> Void
    let onOpenCapture: (ScreenshotCapture) -> Void
    let onNewCapture: () -> Void

    @FocusState private var focusedField: ScreenshotAnnotationModel.DictationTarget?
    @State private var showDiscardConfirmation = false

    @State private var showShortcuts = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            switch model.tab {
            case .annotate:
                HSplitView {
                    canvasPane
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    sidebar
                        .frame(minWidth: 300, idealWidth: 340, maxWidth: 460)
                }
            case .preview:
                VStack(spacing: 0) {
                    if model.isReviewingForExport {
                        reviewBanner
                        Divider()
                    }
                    ScreenshotPreviewView(store: store)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            bottomBar
        }
        .frame(minWidth: 900, minHeight: 560)
        .onChange(of: model.selectedRegionID) { _, newValue in
            if let id = newValue {
                focusedField = .region(id)
            }
        }
        .onChange(of: focusedField) { _, newValue in
            if case .region(let id)? = newValue {
                model.selectedRegionID = id
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $model.tab) {
                ForEach(ScreenshotAnnotationModel.Tab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)

            Spacer()

            TextField(
                "Session title (optional)",
                text: Binding(
                    get: { store.session.title },
                    set: { store.setSessionTitle($0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 320)

            Button {
                ScreenshotHistoryWindowController.shared.showWindow()
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .keyboardShortcut("y", modifiers: .command)
            .help("Recent sessions: copy their PDF/ZIP again, send to an agent or reopen (⌘Y)")

            Button {
                showShortcuts.toggle()
            } label: {
                Label("Shortcuts", systemImage: "keyboard")
            }
            .keyboardShortcut("/", modifiers: .command)
            .help("Show all keyboard shortcuts (⌘/)")
            .popover(isPresented: $showShortcuts, arrowEdge: .bottom) {
                ScrollView {
                    ShortcutCheatSheet()
                        .padding(16)
                }
                .frame(width: 420, height: 520)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var reviewBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Review before export")
                    .font(.subheadline.weight(.semibold))
                Text("This is exactly what your agent gets: \(store.session.captures.count) screenshot\(store.session.captures.count == 1 ? "" : "s"), task, notes and marked areas. Click a thumbnail below to change something, or press ↩ to export right away.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                model.isReviewingForExport = false
                model.tab = .annotate
            } label: {
                Text("Keep editing")
            }
            Button {
                onFinish()
            } label: {
                HStack(spacing: 6) {
                    Label("Export now", systemImage: "paperplane.fill")
                    KeyHint("↩", onAccent: true)
                }
            }
            .buttonStyle(.borderedProminent)
            .help("Export and put the hand-off on the clipboard (↩ or ⇧⌘E)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08))
    }

    // MARK: Canvas

    private var canvasPane: some View {
        VStack(spacing: 0) {
            AnnotationCanvas(model: model)
                .background(Color(nsColor: .underPageBackgroundColor))

            HStack(spacing: 6) {
                Image(systemName: "rectangle.dashed")
                    .foregroundColor(.secondary)
                Text("Drag on the screenshot to mark an area, then describe it on the right.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(ShortcutConfig.annotateScreenshot.displayString) next screenshot · \(ShortcutConfig.finishScreenshotSession.displayString) export")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("\(model.capture.pixelWidth)×\(model.capture.pixelHeight) px")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                taskSection
                Divider()
                header
                generalNoteSection
                Divider()
                regionsSection
            }
            .padding(14)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Screenshot \(model.capture.index)")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(model.capture.displayTitle)
                .font(.headline)
                .lineLimit(2)
            if let url = model.capture.pageURL, !url.isEmpty {
                Text(url)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let app = model.capture.appName {
                Text(app)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(4)
            }
        }
    }

    /// Session-wide instruction – becomes the first section of notes.md and the prompt for "Send to Claude Code".
    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.accentColor)
                Text("Task for the agent")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("whole session")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            TextField(
                "e.g. Rebuild this landing page · Find the bugs shown here · Compare these offers",
                text: Binding(
                    get: { store.session.task },
                    set: { store.setSessionTask($0) }
                ),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(2...5)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 1))
            .cornerRadius(6)
        }
    }

    private var generalNoteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Notes on this page")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("Type, click Dictate, or press \(ShortcutConfig.recording.displayString)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            noteEditor(text: $model.capture.generalNote, field: .general, minHeight: 100)
        }
    }

    private var regionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Marked areas")
                    .font(.subheadline.weight(.medium))
                if !model.capture.regions.isEmpty {
                    Text("\(model.capture.regions.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            if model.capture.regions.isEmpty {
                Text("No areas marked yet. Drag a rectangle on the screenshot to comment on a specific part.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(model.capture.regions.enumerated()), id: \.element.id) { offset, region in
                    regionRow(number: offset + 1, region: region)
                }
            }
        }
    }

    private func regionRow(number: Int, region: ScreenshotRegion) -> some View {
        let isSelected = model.selectedRegionID == region.id
        let binding = Binding<String>(
            get: { model.capture.regions.first { $0.id == region.id }?.note ?? "" },
            set: { newValue in
                if let idx = model.capture.regions.firstIndex(where: { $0.id == region.id }) {
                    model.capture.regions[idx].note = newValue
                }
            }
        )

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RegionBadge(number: number, size: 20)
                Text("Area \(number)")
                    .font(.caption.weight(.medium))
                Spacer()
                Button {
                    model.removeRegion(region.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Remove area")
            }
            noteEditor(text: binding, field: .region(region.id), minHeight: 76)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedRegionID = region.id
        }
    }

    /// Text box with a dictation button in its bottom-right corner.
    private func noteEditor(text: Binding<String>, field: ScreenshotAnnotationModel.DictationTarget, minHeight: CGFloat) -> some View {
        let isRecordingHere = model.dictationTarget == field && model.dictation.state == .recording
        let isEmpty = text.wrappedValue.isEmpty

        return VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if isEmpty {
                    Text(field == .general ? "What is this page about, what should the agent do with it?" : "What about this part of the page?")
                        .font(.body)
                        .foregroundColor(Color(nsColor: .placeholderTextColor))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: text)
                    .font(.body)
                    .focused($focusedField, equals: field)
                    .frame(minHeight: minHeight)
                    .scrollContentBackground(.hidden)
            }
            .padding(6)

            HStack {
                if let error = model.dictation.errorMessage, model.dictationTarget == field || model.dictationTarget == nil {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
                Spacer()
                dictationButton(for: field)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isRecordingHere ? Color.red : Color.gray.opacity(0.3), lineWidth: isRecordingHere ? 2 : 1)
        )
        .cornerRadius(6)
    }

    private func dictationButton(for target: ScreenshotAnnotationModel.DictationTarget) -> some View {
        let isActive = model.dictationTarget == target
        let state = model.dictation.state
        let disabled = model.dictation.isBusy && !isActive
        let isRecording = isActive && state == .recording
        let isTranscribing = isActive && state == .transcribing

        return Button {
            model.toggleDictation(for: target)
        } label: {
            HStack(spacing: 5) {
                if isTranscribing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Transcribing…")
                } else if isRecording {
                    Image(systemName: "stop.fill")
                    Text("Stop & insert")
                } else {
                    Image(systemName: "mic.fill")
                    Text("Dictate")
                }
            }
            .font(.caption.weight(.medium))
            .frame(minWidth: 96)
        }
        .buttonStyle(.borderedProminent)
        .tint(isRecording ? .red : .accentColor)
        .controlSize(.small)
        .disabled(disabled)
        .help(isRecording ? "Stop recording and insert the transcription here" : "Record a voice note for this box (or use \(ShortcutConfig.recording.displayString) while the box is focused)")
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if model.tab == .preview {
                // On the review page plain ↩ exports immediately
                Button(action: onFinish) { EmptyView() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(store.session.captures.isEmpty || model.isFinishingRecording)
                    .hidden()
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            sessionStrip
            Spacer()
            Button("Discard", role: .destructive) {
                showDiscardConfirmation = true
            }
            .help("Remove this screenshot from the session")
            .confirmationDialog(
                "Remove screenshot \(model.capture.index) from the session?",
                isPresented: $showDiscardConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove Screenshot", role: .destructive, action: onDiscard)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The screenshot and its notes are deleted from the session folder. The remaining screenshots are renumbered.")
            }
            Button(action: saveStoppingRecording) {
                HStack(spacing: 6) {
                    if model.isFinishingRecording {
                        ProgressView().controlSize(.small)
                        Text("Finishing recording…")
                    } else {
                        Text("Save")
                        KeyHint("⌘↩")
                    }
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.isFinishingRecording)
            .help("Save notes and close (⌘↩). A running recording is stopped and added to the selected note first.")
            Menu {
                Button(action: onSendLocal) {
                    Label("Send to Claude Code (this Mac)   ⇧⌘K", systemImage: "terminal")
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                Button(action: onSendVM) {
                    Label("Send to VM of current iTerm tab", systemImage: "server.rack")
                }
                Divider()
                Button(action: onCopyMarkdown) {
                    Label("Copy Markdown   ⇧⌘C", systemImage: "doc.on.clipboard")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                Button(action: onExportZip) {
                    Label("Export ZIP…   ⇧⌘Z", systemImage: "doc.zipper")
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                Button(action: onExportPDF) {
                    Label("Export PDF…   ⇧⌘P", systemImage: "doc.fill")
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(store.session.captures.isEmpty)
            .help("Send to Claude Code (⇧⌘K), copy Markdown (⇧⌘C), export ZIP (⇧⌘Z) or PDF (⇧⌘P)")
            Button {
                if model.tab == .preview {
                    onFinish()
                } else {
                    model.isReviewingForExport = true
                    model.tab = .preview
                }
            } label: {
                HStack(spacing: 6) {
                    Label(model.tab == .preview ? "Export now" : "Review & Export", systemImage: model.tab == .preview ? "paperplane.fill" : "doc.richtext")
                    KeyHint(model.tab == .preview ? "↩" : "⇧⌘E", onAccent: true)
                }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .buttonStyle(.borderedProminent)
            .disabled(store.session.captures.isEmpty || model.isFinishingRecording)
            .help(model.tab == .preview
                  ? "Write notes.md, PDF and ZIP for all \(store.session.captures.count) screenshots and put the hand-off on the clipboard (↩ or ⇧⌘E)"
                  : "Show everything the agent will get, then export (⇧⌘E)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var sessionStrip: some View {
        HStack(spacing: 8) {
            Text("Session")
                .font(.caption)
                .foregroundColor(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.session.captures) { capture in
                        sessionThumbnail(capture)
                    }
                    Button(action: onNewCapture) {
                        Image(systemName: "plus")
                            .frame(width: 44, height: 32)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help("Capture another screenshot (⌃⌥⌘⇧A)")
                }
            }
            .frame(maxWidth: 420)
        }
    }

    /// Save, but first stop a running ⌃⌥⌘⇧R recording and put its text into the
    /// selected area (or the page note).
    private func saveStoppingRecording() {
        guard GlobalDictationBridge.isRecording || GlobalDictationBridge.isProcessing else {
            onSave()
            return
        }
        model.isFinishingRecording = true
        model.dictation.cancel()
        Task { @MainActor in
            let transcript = await GlobalDictationBridge.stopAndCollect()
            model.isFinishingRecording = false
            if let transcript {
                if let id = model.selectedRegionID,
                   let idx = model.capture.regions.firstIndex(where: { $0.id == id }) {
                    let existing = model.capture.regions[idx].note.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.capture.regions[idx].note = existing.isEmpty ? transcript : existing + " " + transcript
                } else {
                    let existing = model.capture.generalNote.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.capture.generalNote = existing.isEmpty ? transcript : existing + " " + transcript
                }
            }
            onSave()
        }
    }

    private func sessionThumbnail(_ capture: ScreenshotCapture) -> some View {
        let isCurrent = capture.id == model.capture.id
        return Button {
            if !isCurrent { onOpenCapture(capture) }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                if let thumb = store.thumbnail(for: capture) {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 32)
                        .clipped()
                } else {
                    Color.gray.opacity(0.3)
                        .frame(width: 44, height: 32)
                }
                Text("\(capture.index)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(2)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(3)
                    .padding(2)
            }
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isCurrent ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .help(capture.displayTitle)
    }
}

// MARK: - Canvas

struct AnnotationCanvas: View {
    @ObservedObject var model: ScreenshotAnnotationModel

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    private let minimumRegionSide: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let fitted = fittedRect(for: model.capture.pixelSize, in: geo.size)

            ZStack(alignment: .topLeading) {
                Color.clear

                Image(nsImage: model.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fitted.width, height: fitted.height)
                    .offset(x: fitted.minX, y: fitted.minY)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)

                ForEach(Array(model.capture.regions.enumerated()), id: \.element.id) { offset, region in
                    let rect = viewRect(for: region.normalizedRect, fitted: fitted)
                    RegionOverlay(
                        number: offset + 1,
                        isSelected: model.selectedRegionID == region.id
                    )
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .onTapGesture {
                        model.selectedRegionID = region.id
                    }
                }

                if let draft = draftRect() {
                    Rectangle()
                        .stroke(Color.red, style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                        .background(Color.red.opacity(0.08))
                        .frame(width: draft.width, height: draft.height)
                        .offset(x: draft.minX, y: draft.minY)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .local)
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = clamp(value.startLocation, to: fitted)
                        }
                        dragCurrent = clamp(value.location, to: fitted)
                    }
                    .onEnded { _ in
                        defer {
                            dragStart = nil
                            dragCurrent = nil
                        }
                        guard let draft = draftRect(),
                              draft.width >= minimumRegionSide,
                              draft.height >= minimumRegionSide
                        else { return }
                        let normalized = CGRect(
                            x: (draft.minX - fitted.minX) / fitted.width,
                            y: (draft.minY - fitted.minY) / fitted.height,
                            width: draft.width / fitted.width,
                            height: draft.height / fitted.height
                        )
                        model.addRegion(normalized)
                    }
            )
        }
        .padding(16)
    }

    // MARK: Geometry helpers

    private func fittedRect(for pixelSize: CGSize, in available: CGSize) -> CGRect {
        guard pixelSize.width > 0, pixelSize.height > 0, available.width > 0, available.height > 0 else {
            return .zero
        }
        let scale = min(available.width / pixelSize.width, available.height / pixelSize.height)
        let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        let origin = CGPoint(
            x: (available.width - size.width) / 2,
            y: (available.height - size.height) / 2
        )
        return CGRect(origin: origin, size: size)
    }

    private func viewRect(for normalized: CGRect, fitted: CGRect) -> CGRect {
        CGRect(
            x: fitted.minX + normalized.minX * fitted.width,
            y: fitted.minY + normalized.minY * fitted.height,
            width: normalized.width * fitted.width,
            height: normalized.height * fitted.height
        )
    }

    private func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private func draftRect() -> CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }
}

// MARK: - Overlay pieces

struct RegionOverlay: View {
    let number: Int
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(isSelected ? Color.red.opacity(0.12) : Color.clear)
            Rectangle()
                .stroke(Color.red, lineWidth: isSelected ? 3 : 2)
            RegionBadge(number: number, size: 22)
                .offset(x: -8, y: -8)
        }
        .contentShape(Rectangle())
    }
}

/// Small inline shortcut hint used inside buttons.
struct KeyHint: View {
    let text: String
    var onAccent = false

    init(_ text: String, onAccent: Bool = false) {
        self.text = text
        self.onAccent = onAccent
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(onAccent ? .white.opacity(0.85) : .secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(onAccent ? Color.white.opacity(0.18) : Color.gray.opacity(0.15))
            )
    }
}

struct RegionBadge: View {
    let number: Int
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red)
            Circle()
                .stroke(Color.white, lineWidth: 1.5)
            Text("\(number)")
                .font(.system(size: size * 0.55, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}
