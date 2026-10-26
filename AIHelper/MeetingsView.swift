import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "MeetingsWindow")

/// Window listing recorded meetings and their transcripts (see `MeetingsView`).
@MainActor
final class MeetingsWindowController {
    static let shared = MeetingsWindowController()

    private var window: NSWindow?
    private let selection = MeetingSelection()

    func showWindow(selecting meetingID: UUID? = nil) {
        if let meetingID {
            selection.meetingID = meetingID
        } else if selection.meetingID == nil {
            selection.meetingID = MeetingStore.shared.meetings.first?.id
        }

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Meetings"
        window.contentView = NSHostingView(rootView: MeetingsView(selection: selection))
        window.center()
        window.setFrameAutosaveName("MeetingsWindow")
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        logger.info("Meetings window shown")
    }
}

/// Which meeting the window shows, so the controller can select one from outside.
@MainActor
final class MeetingSelection: ObservableObject {
    @Published var meetingID: UUID?
}

// MARK: - Window

struct MeetingsView: View {
    @ObservedObject var selection: MeetingSelection
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var recorder = MeetingRecorder.shared
    @AppStorage(MeetingStore.keepAudioKey) private var keepAudio = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection.meetingID) {
                ForEach(store.meetings) { meeting in
                    MeetingRow(meeting: meeting)
                        .tag(meeting.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            if let id = selection.meetingID, let meeting = store.meeting(id: id) {
                MeetingDetailView(meeting: meeting)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 720, minHeight: 420)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                recorder.toggle()
            } label: {
                Label(recorder.isRecording ? "Stop recording" : "Record meeting",
                      systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .tint(recorder.isRecording ? .red : .accentColor)
            .help("\(ShortcutConfig.meetingRecording.displayString) starts and stops a meeting recording")

            Toggle("Keep audio after transcribing", isOn: $keepAudio)
                .font(.caption)
                .help("Off: the recording is deleted once every part is transcribed, only the transcript stays.")
        }
        .padding(12)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(store.meetings.isEmpty ? "No meetings yet" : "Select a meeting")
                .font(.title3)
            Text("Press \(ShortcutConfig.meetingRecording.displayString) when a call starts. AIHelper records your microphone and whatever your Mac plays — nothing joins the call — and transcribes it when you stop.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text("Let everyone know you are recording. In many places, including Germany, recording a conversation without consent is against the law.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title)
                .font(.body)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(meeting.startedAt, format: .dateTime.day().month().hour().minute())
                if meeting.duration > 0 {
                    Text("· \(Int((meeting.duration / 60).rounded(.up))) min")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            MeetingStatusLabel(meeting: meeting)
                .font(.caption2)
        }
        .padding(.vertical, 3)
    }
}

/// One line saying where a meeting stands; empty once it is transcribed without problems.
private struct MeetingStatusLabel: View {
    let meeting: Meeting

    var body: some View {
        switch meeting.status {
        case .recording:
            Label("Recording", systemImage: "record.circle.fill").foregroundColor(.red)
        case .transcribing:
            Label(meeting.segments.isEmpty ? "Preparing…" : "Transcribing \(meeting.transcribedCount + meeting.failedCount) of \(meeting.segments.count)",
                  systemImage: "waveform")
                .foregroundColor(.accentColor)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange)
        case .done:
            if meeting.failedCount > 0 {
                Label("\(meeting.failedCount) parts failed", systemImage: "exclamationmark.triangle").foregroundColor(.orange)
            }
        }
    }
}

// MARK: - Detail

private struct MeetingDetailView: View {
    let meeting: Meeting
    @ObservedObject private var store = MeetingStore.shared
    @State private var title = ""
    @State private var confirmDelete = false

    private static let speakerColors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            statusBanner
            if !meeting.speakers.isEmpty {
                speakers
                Divider()
            }
            transcript
        }
        .onAppear { title = meeting.title }
        .onChange(of: meeting.id) { title = meeting.title }
        .confirmationDialog("Delete “\(meeting.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { store.delete(meeting) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The meeting folder with its transcript and any audio is moved to the Trash.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .onSubmit { store.rename(meeting.id, to: title) }
                Text(subtitle)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                store.copyTranscript(of: meeting)
                StatusOverlay.shared.showBrief(message: "Transcript copied")
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(meeting.speakers.isEmpty)
            .help("Copy the transcript to the clipboard")

            Button {
                store.revealInFinder(meeting)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(meeting.status == .recording)
        }
        .labelStyle(.iconOnly)
        .padding(16)
    }

    private var subtitle: String {
        let date = meeting.startedAt.formatted(date: .complete, time: .shortened)
        let minutes = Int((meeting.duration / 60).rounded(.up))
        return meeting.duration > 0 ? "\(date) · \(minutes) min" : date
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch meeting.status {
        case .recording:
            banner("Recording… stop with \(ShortcutConfig.meetingRecording.displayString) to get the transcript.", symbol: "record.circle.fill", color: .red)
        case .transcribing:
            VStack(alignment: .leading, spacing: 6) {
                if meeting.segments.isEmpty {
                    ProgressView().controlSize(.small)
                    Text("Finding who speaks when…").font(.callout).foregroundColor(.secondary)
                } else {
                    ProgressView(value: Double(meeting.transcribedCount + meeting.failedCount), total: Double(meeting.segments.count))
                    Text("Transcribing part \(meeting.transcribedCount + meeting.failedCount) of \(meeting.segments.count)")
                        .font(.callout).foregroundColor(.secondary)
                }
            }
            .padding(16)
            Divider()
        case .failed:
            HStack {
                banner(meeting.failureReason ?? "Transcription failed.", symbol: "exclamationmark.triangle.fill", color: .orange)
                if store.hasAudio(meeting) {
                    Button("Try again") { MeetingTranscriber.shared.retry(meetingID: meeting.id) }
                        .padding(.trailing, 16)
                }
            }
        case .done:
            if meeting.failedCount > 0 {
                HStack {
                    banner("\(meeting.failedCount) parts could not be transcribed.", symbol: "exclamationmark.triangle", color: .orange)
                    if store.hasAudio(meeting) {
                        Button("Retry") { MeetingTranscriber.shared.retry(meetingID: meeting.id) }
                            .padding(.trailing, 16)
                    }
                }
            } else if meeting.capturedSystemAudio, !meeting.segments.contains(where: { $0.track == .system }) {
                banner("Nothing from the Mac's audio was transcribed. If others spoke, check that AIHelper may record system audio in System Settings › Privacy & Security › Screen & System Audio Recording.",
                       symbol: "speaker.slash", color: .secondary)
            }
        }
    }

    private func banner(_ text: String, symbol: String, color: Color) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol).foregroundColor(color)
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            Divider()
        }
    }

    private var speakers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speakers — rename one and the whole transcript follows")
                .font(.caption)
                .foregroundColor(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], alignment: .leading, spacing: 8) {
                ForEach(meeting.speakers, id: \.self) { speaker in
                    SpeakerNameField(meetingID: meeting.id, speaker: speaker,
                                     savedName: meeting.speakerNames[speaker] ?? "",
                                     color: color(for: speaker))
                }
            }
        }
        .padding(16)
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                let paragraphs = MeetingTranscript.paragraphs(for: meeting)
                if paragraphs.isEmpty, meeting.status == .done {
                    Text("No speech was transcribed.")
                        .foregroundColor(.secondary)
                }
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(meeting.name(for: paragraph.speaker))
                                .fontWeight(.semibold)
                                .foregroundColor(color(for: paragraph.speaker))
                            Text(MeetingTranscript.timestamp(paragraph.start))
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        Text(paragraph.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func color(for speaker: String) -> Color {
        let index = meeting.speakers.firstIndex(of: speaker) ?? 0
        return Self.speakerColors[index % Self.speakerColors.count]
    }
}

private struct SpeakerNameField: View {
    let meetingID: UUID
    let speaker: String
    let savedName: String
    let color: Color
    @State private var name = ""

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            TextField(MeetingSpeaker.defaultName(for: speaker), text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { MeetingStore.shared.renameSpeaker(speaker, to: name, in: meetingID) }
        }
        .onAppear { name = savedName }
        .onChange(of: savedName) { name = savedName }
    }
}

// MARK: - Menu-bar popover

/// Start/stop a meeting recording from the popover, and see where the last one stands.
struct MeetingStatusBar: View {
    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var transcriber = MeetingTranscriber.shared
    @ObservedObject private var store = MeetingStore.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "person.2.wave.2")
                .foregroundColor(recorder.isRecording ? .red : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                Text(subtitle)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Meetings") {
                MeetingsWindowController.shared.showWindow(selecting: transcriber.activeMeetingID)
            }
            .font(.caption2)
            .buttonStyle(.borderless)

            Button(recorder.isRecording ? "Stop" : "Record") {
                recorder.toggle()
            }
            .font(.caption2)
            .accessibilityLabel(recorder.isRecording ? "Stop meeting recording" : "Record meeting")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(recorder.isRecording ? Color.red.opacity(0.1) : Color.gray.opacity(0.1))
        .cornerRadius(8)
    }

    private var transcribing: Meeting? {
        transcriber.activeMeetingID.flatMap { store.meeting(id: $0) }
    }

    private var title: String {
        if recorder.isRecording {
            return "Recording meeting · \(MeetingTranscript.timestamp(recorder.elapsed))"
        }
        if transcribing != nil {
            return "Transcribing meeting"
        }
        return "Record a meeting"
    }

    private var subtitle: String {
        if recorder.isRecording {
            let source = recorder.capturesSystemAudio ? "Microphone + Mac audio" : "Microphone only"
            return "\(source) · \(ShortcutConfig.meetingRecording.displayString) stops"
        }
        if let meeting = transcribing {
            return meeting.segments.isEmpty
                ? "Finding who speaks when…"
                : "Part \(meeting.transcribedCount + meeting.failedCount) of \(meeting.segments.count)"
        }
        return "\(ShortcutConfig.meetingRecording.displayString) · transcribes everyone on the call"
    }
}
