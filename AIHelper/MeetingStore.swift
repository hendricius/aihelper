import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "MeetingStore")

/// Every recorded meeting, one folder each: `meeting.json`, the rendered `transcript.md`, and
/// the two audio tracks until they are transcribed.
///
/// Folders rather than UserDefaults (where dictation history lives): a meeting transcript runs
/// to thousands of words, and plain files on disk can be read by agents and other tools as is.
@MainActor
final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()

    /// Next to Screenshot Notes, in Application Support so meetings survive reboots.
    static let defaultRootPath = "~/Library/Application Support/AIHelper/Meetings"
    /// UserDefaults key: keep the audio tracks after the transcript is done.
    static let keepAudioKey = "meetings.keepAudio"

    let root: URL
    /// Newest first.
    @Published private(set) var meetings: [Meeting] = []
    /// Deleted meetings go to the Trash; tests delete for good instead of filling it.
    private let usesTrash: Bool

    init(root: URL? = nil, usesTrash: Bool = true) {
        self.root = root ?? URL(fileURLWithPath: (Self.defaultRootPath as NSString).expandingTildeInPath, isDirectory: true)
        self.usesTrash = usesTrash
        reload()
    }

    static var keepsAudio: Bool {
        UserDefaults.standard.bool(forKey: keepAudioKey)
    }

    func meeting(id: UUID) -> Meeting? {
        meetings.first { $0.id == id }
    }

    func folder(for meeting: Meeting) -> URL {
        root.appendingPathComponent(meeting.folderName, isDirectory: true)
    }

    func audioURL(for track: MeetingTrack, of meeting: Meeting) -> URL {
        folder(for: meeting).appendingPathComponent(track.fileName)
    }

    func transcriptURL(for meeting: Meeting) -> URL {
        folder(for: meeting).appendingPathComponent(Meeting.transcriptFileName)
    }

    func hasAudio(_ meeting: Meeting) -> Bool {
        [MeetingTrack.microphone, .system].contains { FileManager.default.fileExists(atPath: audioURL(for: $0, of: meeting).path) }
    }

    // MARK: - Changes

    /// Creates the folder for a new recording, named after its start time.
    func createMeeting(startedAt date: Date) throws -> Meeting {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let base = "\(formatter.string(from: date)) Meeting"

        var name = base
        var counter = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
            name = "\(base) \(counter)"
            counter += 1
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)

        let meeting = Meeting(title: Meeting.defaultTitle(for: date), startedAt: date, folderName: name)
        update(meeting)
        return meeting
    }

    /// Replaces the stored meeting with the same id (or adds it) and writes it to disk.
    func update(_ meeting: Meeting) {
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.append(meeting)
            meetings.sort { $0.startedAt > $1.startedAt }
        }
        save(meeting)
    }

    func rename(_ meetingID: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var meeting = meeting(id: meetingID) else { return }
        meeting.title = trimmed
        update(meeting)
    }

    /// Renames a speaker throughout one meeting's transcript. An empty name restores the default.
    func renameSpeaker(_ speaker: String, to name: String, in meetingID: UUID) {
        guard var meeting = meeting(id: meetingID) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting.speakerNames[speaker] = trimmed.isEmpty ? nil : trimmed
        update(meeting)
    }

    /// Moves the meeting's folder to the Trash.
    func delete(_ meeting: Meeting) {
        let folder = folder(for: meeting)
        do {
            if usesTrash {
                try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
            } else {
                try FileManager.default.removeItem(at: folder)
            }
        } catch {
            logger.error("Could not delete \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        meetings.removeAll { $0.id == meeting.id }
    }

    /// Removes a meeting that never got going (recording failed to start) without a Trash detour.
    func discard(_ meeting: Meeting) {
        try? FileManager.default.removeItem(at: folder(for: meeting))
        meetings.removeAll { $0.id == meeting.id }
    }

    /// Removes the audio tracks, keeping the transcript.
    func deleteAudio(of meeting: Meeting) {
        for track in [MeetingTrack.microphone, .system] {
            try? FileManager.default.removeItem(at: audioURL(for: track, of: meeting))
        }
        objectWillChange.send()
    }

    func copyTranscript(of meeting: Meeting) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(MeetingTranscript.text(for: meeting), forType: .string)
    }

    func revealInFinder(_ meeting: Meeting) {
        let transcript = transcriptURL(for: meeting)
        let target = FileManager.default.fileExists(atPath: transcript.path) ? transcript : folder(for: meeting)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: - Disk

    /// Reads every meeting folder under the root.
    func reload() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        let decoder = Self.decoder
        meetings = names.compactMap { name -> Meeting? in
            let url = root.appendingPathComponent(name).appendingPathComponent(Meeting.metadataFileName)
            guard let data = try? Data(contentsOf: url) else { return nil }
            do {
                return try decoder.decode(Meeting.self, from: data)
            } catch {
                logger.error("Skipping unreadable \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    private func save(_ meeting: Meeting) {
        let folder = folder(for: meeting)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(meeting)
            try data.write(to: folder.appendingPathComponent(Meeting.metadataFileName), options: .atomic)
            if meeting.status == .done {
                try MeetingTranscript.markdown(for: meeting)
                    .write(to: transcriptURL(for: meeting), atomically: true, encoding: .utf8)
            }
        } catch {
            logger.error("Saving meeting \(meeting.folderName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
