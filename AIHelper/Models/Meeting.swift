import Foundation

/// One recorded meeting.
///
/// While recording it is two audio tracks in its own folder under `MeetingStore.root`:
/// `microphone.caf` (you) and `system.caf` (everything the Mac plays — the other people on
/// the call). Afterwards it is a list of transcribed segments, each tagged with a speaker,
/// rendered to `transcript.md` next to `meeting.json`.
struct Meeting: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        case recording
        case transcribing
        case done
        case failed
    }

    static let metadataFileName = "meeting.json"
    static let transcriptFileName = "transcript.md"

    let id: UUID
    var title: String
    let startedAt: Date
    /// Name of the meeting's folder under the store's root.
    let folderName: String
    var duration: TimeInterval = 0
    var status: Status = .recording
    /// Why the meeting could not be transcribed, when `status == .failed`.
    var failureReason: String?
    /// False when only the microphone was recorded (no system audio tap available).
    var capturedSystemAudio = true
    var segments: [MeetingSegment] = []
    /// Display names by speaker key. Renaming a speaker here renames them in the whole transcript.
    var speakerNames: [String: String] = [:]

    init(id: UUID = UUID(), title: String, startedAt: Date, folderName: String) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.folderName = folderName
    }

    /// The name shown for a speaker key: the user's rename, or "Me", "Them", "Speaker 2".
    func name(for speaker: String) -> String {
        let custom = speakerNames[speaker]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? MeetingSpeaker.defaultName(for: speaker) : custom
    }

    /// Speaker keys that say something in the transcript, in order of first appearance.
    var speakers: [String] {
        var seen = Set<String>()
        return segments
            .sorted { $0.start < $1.start }
            .filter { !($0.text ?? "").isEmpty }
            .compactMap { seen.insert($0.speaker).inserted ? $0.speaker : nil }
    }

    var transcribedCount: Int { segments.filter { $0.text != nil }.count }
    var failedCount: Int { segments.filter { $0.error != nil }.count }
    var pendingCount: Int { segments.filter(\.isPending).count }

    static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Meeting \(formatter.string(from: date))"
    }
}

/// Which recording a segment was cut from.
enum MeetingTrack: String, Codable {
    /// Your microphone.
    case microphone
    /// The Mac's audio output: whoever is on the call.
    case system

    var fileName: String {
        switch self {
        case .microphone: return "microphone.caf"
        case .system: return "system.caf"
        }
    }
}

/// One stretch of speech by one speaker — one transcription request.
struct MeetingSegment: Codable, Identifiable, Equatable {
    let id: UUID
    let track: MeetingTrack
    /// Speaker key, see `MeetingSpeaker`.
    var speaker: String
    /// Seconds from the start of the recording.
    let start: TimeInterval
    let end: TimeInterval
    /// The transcription; "" when the stretch turned out to hold no words.
    var text: String?
    /// Why transcribing this stretch failed; it can be retried while the audio is kept.
    var error: String?

    init(id: UUID = UUID(), track: MeetingTrack, speaker: String, start: TimeInterval, end: TimeInterval) {
        self.id = id
        self.track = track
        self.speaker = speaker
        self.start = start
        self.end = end
    }

    var duration: TimeInterval { end - start }
    var isPending: Bool { text == nil && error == nil }
}

/// Speaker keys. Keys stay stable when the user renames someone; only the display name changes.
enum MeetingSpeaker {
    /// The microphone's owner.
    static let me = "me"
    /// Everyone on the system track, when it could not be split into individual voices.
    static let them = "them"

    static func numbered(_ number: Int) -> String { "speaker-\(number)" }

    static func defaultName(for key: String) -> String {
        switch key {
        case me: return "Me"
        case them: return "Them"
        default:
            if key.hasPrefix("speaker-"), let number = Int(key.dropFirst("speaker-".count)) {
                return "Speaker \(number)"
            }
            return key
        }
    }
}

/// A stretch of a track and who speaks in it, before it is transcribed.
struct SpeakerSpan: Equatable, Sendable {
    var speaker: String
    var start: TimeInterval
    var end: TimeInterval

    var duration: TimeInterval { end - start }
}

/// Turns raw speech stretches into transcription requests.
enum MeetingTurns {
    /// Joins one speaker's stretches when only a short pause separates them, splits very long
    /// ones and drops blips, so every turn makes one sensible transcription request: long
    /// enough to carry context, short enough to come back quickly.
    static func turns(
        from spans: [SpeakerSpan],
        maxGap: TimeInterval = 1.0,
        maxLength: TimeInterval = 45,
        minLength: TimeInterval = 0.6
    ) -> [SpeakerSpan] {
        var merged: [SpeakerSpan] = []
        for span in spans.sorted(by: { $0.start < $1.start }) where span.duration > 0 {
            if var last = merged.last,
               last.speaker == span.speaker,
               span.start - last.end <= maxGap,
               span.end - last.start <= maxLength {
                last.end = max(last.end, span.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(span)
            }
        }

        return merged
            .flatMap { split($0, maxLength: maxLength) }
            .filter { $0.duration >= minLength }
    }

    /// Renames whatever labels a diarizer produced to "speaker-1", "speaker-2", … in order of
    /// first appearance, so the first voice heard is Speaker 1.
    static func numberingSpeakers(_ spans: [SpeakerSpan]) -> [SpeakerSpan] {
        var numbers: [String: Int] = [:]
        return spans.sorted { $0.start < $1.start }.map { span in
            let number = numbers[span.speaker] ?? (numbers.count + 1)
            numbers[span.speaker] = number
            return SpeakerSpan(speaker: MeetingSpeaker.numbered(number), start: span.start, end: span.end)
        }
    }

    private static func split(_ span: SpeakerSpan, maxLength: TimeInterval) -> [SpeakerSpan] {
        guard span.duration > maxLength else { return [span] }
        let parts = Int((span.duration / maxLength).rounded(.up))
        let length = span.duration / Double(parts)
        return (0..<parts).map { index in
            SpeakerSpan(
                speaker: span.speaker,
                start: span.start + Double(index) * length,
                end: index == parts - 1 ? span.end : span.start + Double(index + 1) * length
            )
        }
    }
}

/// Turns transcribed segments into the transcript people read.
enum MeetingTranscript {
    /// Same-speaker parts closer together than this read as one paragraph.
    static let paragraphGap: TimeInterval = 5

    struct Paragraph: Equatable {
        let start: TimeInterval
        let speaker: String
        let text: String
    }

    /// Transcribed segments in time order, with consecutive parts by the same speaker joined.
    static func paragraphs(for meeting: Meeting) -> [Paragraph] {
        var paragraphs: [Paragraph] = []
        var lastEnd: TimeInterval = -.infinity
        for segment in meeting.segments.sorted(by: { $0.start < $1.start }) {
            let text = (segment.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = paragraphs.last, last.speaker == segment.speaker, segment.start - lastEnd < paragraphGap {
                paragraphs[paragraphs.count - 1] = Paragraph(start: last.start, speaker: last.speaker, text: last.text + " " + text)
            } else {
                paragraphs.append(Paragraph(start: segment.start, speaker: segment.speaker, text: text))
            }
            lastEnd = max(lastEnd, segment.end)
        }
        return paragraphs
    }

    /// The transcript body: one "[mm:ss] Name: text" paragraph per turn.
    static func text(for meeting: Meeting) -> String {
        paragraphs(for: meeting)
            .map { "[\(timestamp($0.start))] \(meeting.name(for: $0.speaker)): \($0.text)" }
            .joined(separator: "\n\n")
    }

    /// `transcript.md`: a title line, when and who, then the transcript.
    static func markdown(for meeting: Meeting) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        var header = [formatter.string(from: meeting.startedAt), "\(Int((meeting.duration / 60).rounded())) min"]
        let names = meeting.speakers.map { meeting.name(for: $0) }
        if !names.isEmpty { header.append(names.joined(separator: ", ")) }

        let body = text(for: meeting)
        return "# \(meeting.title)\n\n\(header.joined(separator: " · "))\n\n\(body.isEmpty ? "_No speech was transcribed._" : body)\n"
    }

    /// "04:05", or "1:02:03" past the first hour.
    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// Drops microphone segments that only repeat what the system track says at the same
    /// time: on laptop speakers the microphone hears the other people too, and without this
    /// every remote sentence would also show up as yours.
    static func removingEcho(from segments: [MeetingSegment], minimumOverlap: Double = 0.3, minimumShared: Double = 0.6) -> [MeetingSegment] {
        let system = segments.filter { $0.track == .system && !($0.text ?? "").isEmpty }
        guard !system.isEmpty else { return segments }

        return segments.filter { segment in
            guard segment.track == .microphone, let text = segment.text, !text.isEmpty, segment.duration > 0 else { return true }
            let overlapping = system.filter { other in
                min(segment.end, other.end) - max(segment.start, other.start) >= minimumOverlap * segment.duration
            }
            guard !overlapping.isEmpty else { return true }
            let heard = words(in: overlapping.compactMap(\.text).joined(separator: " "))
            let said = words(in: text)
            guard !said.isEmpty else { return true }
            let shared = said.filter { heard.contains($0) }.count
            return Double(shared) / Double(said.count) < minimumShared
        }
    }

    /// The transcription with prompt read-backs removed. On near-silent audio a transcription
    /// model can return its own prompt (the vocabulary list) instead of speech.
    static func cleaned(_ text: String, promptHint: String?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hint = promptHint, !hint.isEmpty else { return trimmed }
        let said = words(in: trimmed).joined(separator: " ")
        guard !said.isEmpty else { return trimmed }
        return words(in: hint).joined(separator: " ").contains(said) ? "" : trimmed
    }

    private static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
