import AppKit
import SwiftUI

/// State of the small note popup shown next to a marked area.
@MainActor
final class QuickNoteModel: ObservableObject {
    enum Action {
        case done
        case addArea
        case openEditor
    }

    @Published var text = ""
    @Published var status: String?
    let areaNumber: Int?
    let pageTitle: String
    let thumbnail: NSImage?
    let dictation = DictationController()

    private var finished = false
    /// True when a dictation kept running after the popup was saved; its text
    /// arrives later via `onBackgroundTranscript`.
    private(set) var scheduledBackgroundTranscription = false

    var onFinish: ((Action, String) -> Void)?
    var onCancel: (() -> Void)?
    /// Called – possibly long after the popup is gone – with a transcript that
    /// finished in the background ("" when it failed or was empty).
    var onBackgroundTranscript: ((String) -> Void)?

    init(areaNumber: Int?, pageTitle: String, thumbnail: NSImage?) {
        self.areaNumber = areaNumber
        self.pageTitle = pageTitle
        self.thumbnail = thumbnail
    }

    var isRecording: Bool { dictation.state == .recording }
    var isTranscribing: Bool { dictation.state == .transcribing }

    func startDictationIfWanted() {
        guard ScreenshotNotesStore.autoDictateEnabled, dictation.state == .idle else { return }
        if GlobalDictationBridge.isRecording {
            // The user is already dictating with the global hotkey – don't fight over the mic
            status = "Recording via \(ShortcutConfig.recording.displayString) – press ↩ when done"
            ScreenshotNotesLog.log("HUD: global recording active, skipping auto-dictation")
            return
        }
        toggleDictation()
    }

    func toggleDictation() {
        ScreenshotNotesLog.log("HUD dictation toggle (state \(String(describing: dictation.state)))")
        // Strong capture on purpose: the model must stay alive until a
        // transcript that finished after "Done" reached the saved note.
        dictation.toggle { [self] transcript in
            if finished {
                ScreenshotNotesLog.log("HUD transcript arrived after save (\(transcript.count) chars) – appending in background")
                onBackgroundTranscript?(transcript)
                return
            }
            ScreenshotNotesLog.log("HUD transcript received (\(transcript.count) chars)")
            append(transcript)
            status = dictation.errorMessage
        }
        if dictation.state == .recording {
            status = "Listening…"
        } else if dictation.state == .transcribing {
            status = "Transcribing…"
        } else if let error = dictation.errorMessage {
            status = error
        }
    }

    /// Saves immediately with the text typed/transcribed so far. A dictation
    /// that is still recording or transcribing – the popup's own or the global
    /// ⌃⌥⌘⇧R recording – keeps running in the background; its text is appended
    /// to the saved note via `onBackgroundTranscript`, so the user can take the
    /// next screenshot right away instead of waiting for the transcription.
    func finish(_ action: Action) {
        guard !finished else { return }
        ScreenshotNotesLog.log("HUD finish \(action) (dictation \(String(describing: dictation.state)), global recording \(GlobalDictationBridge.isRecording), \(text.count) chars)")

        if GlobalDictationBridge.isRecording || GlobalDictationBridge.isProcessing {
            scheduledBackgroundTranscription = true
            let deliver = onBackgroundTranscript
            Task { @MainActor in
                let transcript = await GlobalDictationBridge.stopAndCollect()
                deliver?(transcript ?? "")
            }
            complete(action)
            return
        }

        switch dictation.state {
        case .idle:
            complete(action)
        case .recording:
            scheduledBackgroundTranscription = true
            // Complete first so a synchronously delivered result (too-short
            // audio) already takes the background route and balances the
            // pending counter; then stop the recorder.
            complete(action)
            toggleDictation()
        case .transcribing:
            scheduledBackgroundTranscription = true
            complete(action)  // the running transcription delivers in the background
        }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        dictation.cancel()
        onCancel?()
    }

    private func complete(_ action: Action) {
        guard !finished else { return }
        finished = true
        onFinish?(action, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func append(_ transcript: String) {
        guard !transcript.isEmpty else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = trimmed.isEmpty ? transcript : trimmed + " " + transcript
    }
}

struct QuickNoteHUDView: View {
    @ObservedObject var model: QuickNoteModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let number = model.areaNumber {
                    RegionBadge(number: number, size: 20)
                    Text("Area \(number)")
                        .font(.headline)
                } else {
                    Image(systemName: "doc.text")
                        .foregroundColor(.secondary)
                    Text("Whole page")
                        .font(.headline)
                }
                Text(model.pageTitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    model.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Discard this area (esc)")
            }

            if let thumb = model.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
            }

            TextField(
                model.areaNumber == nil ? "What about this page? (↩ to save, ⌥↩ for a new line)" : "What about this part? (↩ to save, ⌥↩ for a new line)",
                text: $model.text,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(4, reservesSpace: true)
            .font(.body)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(model.isRecording ? Color.red : Color.gray.opacity(0.3), lineWidth: model.isRecording ? 2 : 1)
            )
            .cornerRadius(6)
            .focused($focused)
            .onSubmit { model.finish(.done) }

            HStack(spacing: 8) {
                Button {
                    model.toggleDictation()
                } label: {
                    HStack(spacing: 5) {
                        if model.isTranscribing {
                            ProgressView().controlSize(.small)
                            Text("Transcribing…")
                        } else if model.isRecording {
                            Image(systemName: "stop.fill")
                            Text("Stop")
                            KeyHint("⌘D", onAccent: true)
                        } else {
                            Image(systemName: "mic.fill")
                            Text("Dictate")
                            KeyHint("⌘D", onAccent: true)
                        }
                    }
                    .font(.caption.weight(.medium))
                    .frame(minWidth: 88)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isRecording ? .red : .accentColor)
                .controlSize(.small)
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model.isTranscribing)

                if let status = model.status {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(model.dictation.errorMessage == nil ? .secondary : .red)
                        .lineLimit(1)
                }

                Spacer()

                Button { model.finish(.addArea) } label: {
                    HStack(spacing: 4) { Text("+ Area"); KeyHint("⌘N") }.fixedSize()
                }
                .controlSize(.small)
                .keyboardShortcut("n", modifiers: .command)
                .help("Save and mark another area on this page (⌘N)")
                Button { model.finish(.openEditor) } label: {
                    HStack(spacing: 4) { Text("Editor"); KeyHint("⌘E") }.fixedSize()
                }
                .controlSize(.small)
                .keyboardShortcut("e", modifiers: .command)
                .help("Save and open the full editor (⌘E)")
                Button { model.finish(.done) } label: {
                    HStack(spacing: 4) { Text("Done"); KeyHint("↩", onAccent: true) }.fixedSize()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }

            Text("⌥↩ new line · esc discard · then \(ShortcutConfig.annotateScreenshot.displayString) next screenshot · \(ShortcutConfig.finishScreenshotSession.displayString) export · \(ShortcutConfig.reviewScreenshotSession.displayString) review")
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 460)
        .background(.regularMaterial)
        .onAppear {
            focused = true
            model.startDictationIfWanted()
        }
    }
}

/// Floating panel hosting `QuickNoteHUDView` near the marked area.
@MainActor
final class QuickNoteHUDController {
    private var panel: NSPanel?

    func show(model: QuickNoteModel, near anchor: NSRect?, on screen: NSScreen) {
        dismiss()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 220),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = false

        // Plain hosting view with a fixed size: letting AppKit resize the window
        // from SwiftUI constraints crashes (_postWindowNeedsUpdateConstraints
        // during a constraint-driven frame change), so size once and freeze.
        let hosting = NSHostingView(rootView: QuickNoteHUDView(model: model))
        // Report the intrinsic size only (no min/max constraints on the window)
        hosting.sizingOptions = [.intrinsicContentSize]
        var size = hosting.intrinsicContentSize
        if size.width <= 0 || size.height <= 0 { size = hosting.fittingSize }
        if size.width <= 0 || size.height <= 0 { size = NSSize(width: 404, height: 260) }
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.setContentSize(size)
        panel.contentView = hosting
        ScreenshotNotesLog.log("HUD size \(Int(size.width))x\(Int(size.height)) for area \(model.areaNumber.map(String.init) ?? "page")")

        let visible = screen.visibleFrame
        var origin: NSPoint
        if let anchor {
            // Prefer below the area, else above, clamped to the screen
            origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 14)
            if origin.y < visible.minY {
                origin.y = anchor.maxY + 14
            }
            if origin.y + size.height > visible.maxY {
                origin.y = visible.maxY - size.height - 8
            }
        } else {
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrameOrigin(origin)
        ScreenshotNotesLog.log("HUD shown at \(Int(origin.x)),\(Int(origin.y)) (anchor \(anchor.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "none"), screen \(screen.localizedName))")

        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        guard let panel else { return }
        ScreenshotNotesLog.log("HUD dismissed")
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }
}
