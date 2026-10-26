import Foundation
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "MeetingTranscriber")

/// Tells who speaks when in a mono track. Optional: without one, everyone on the system track
/// is a single voice, "Them".
protocol SpeakerDiarizer: Sendable {
    /// Speech stretches labelled by speaker. Any labels will do; they are renumbered in order
    /// of first appearance. `progress` reports 0…1 while it works, from any thread.
    func speakerSpans(in url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeakerSpan]
}

/// Turns a recorded meeting into a transcript: finds the speech in each track, tells the
/// speakers apart (`FluidAudioDiarizer`), cuts it into turns, has every turn transcribed
/// through AI Coordinator, and drops the microphone's echo of the call.
@MainActor
final class MeetingTranscriber: ObservableObject {
    static let shared = MeetingTranscriber()

    /// The meeting being transcribed right now.
    @Published private(set) var activeMeetingID: UUID?
    /// How far telling the speakers apart has got (0…1), while it runs for a meeting.
    @Published private(set) var speakerProgress: (meetingID: UUID, fraction: Double)?

    private let store: MeetingStore
    private var queue: [UUID] = []
    private let maxConcurrentRequests = 4

    init(store: MeetingStore = .shared) {
        self.store = store
    }

    /// AI Coordinator when it has a key; otherwise the provider dictation uses, so the feature
    /// still works with only an OpenAI key. Both speak the same transcription API.
    static var provider: APIProvider {
        APIProvider.aiCoordinator.apiKey != nil ? .aiCoordinator : .active
    }

    func transcribe(meetingID: UUID) {
        guard activeMeetingID != meetingID, !queue.contains(meetingID) else { return }
        queue.append(meetingID)
        runNext()
    }

    /// Sends the parts that failed once more. A meeting that failed as a whole is planned anew.
    func retry(meetingID: UUID) {
        guard var meeting = store.meeting(id: meetingID) else { return }
        if meeting.status == .failed {
            meeting.segments = []
            meeting.failureReason = nil
        }
        for index in meeting.segments.indices where meeting.segments[index].error != nil {
            meeting.segments[index].error = nil
        }
        meeting.status = .transcribing
        store.update(meeting)
        transcribe(meetingID: meetingID)
    }

    /// Picks up meetings that were still recording or transcribing when the app last quit.
    func resumeUnfinished() {
        for meeting in store.meetings.reversed() where meeting.status == .recording || meeting.status == .transcribing {
            guard meeting.id != MeetingRecorder.shared.currentMeetingID else { continue }
            var resumed = meeting
            resumed.status = .transcribing
            store.update(resumed)
            transcribe(meetingID: meeting.id)
        }
    }

    private func runNext() {
        guard activeMeetingID == nil, !queue.isEmpty else { return }
        let meetingID = queue.removeFirst()
        activeMeetingID = meetingID
        Task {
            await process(meetingID)
            activeMeetingID = nil
            runNext()
        }
    }

    // MARK: - Pipeline

    private func process(_ meetingID: UUID) async {
        guard let meeting = store.meeting(id: meetingID) else { return }
        let provider = Self.provider
        guard provider.apiKey != nil else {
            fail(meetingID, "Add your AI Coordinator API key in Settings › API to transcribe meetings.")
            return
        }

        let microphoneURL = store.audioURL(for: .microphone, of: meeting)
        let systemURL = store.audioURL(for: .system, of: meeting)

        if meeting.segments.isEmpty {
            guard store.hasAudio(meeting) else {
                fail(meetingID, "The recording is missing.")
                return
            }
            let diarizer = FluidAudioDiarizer.current
            speakerProgress = (meetingID, 0)
            defer { speakerProgress = nil }
            let progress: @Sendable (Double) -> Void = { fraction in
                Task { @MainActor [weak self] in
                    // Ignore updates that arrive after planning finished.
                    guard let self, self.speakerProgress?.meetingID == meetingID else { return }
                    self.speakerProgress = (meetingID, fraction)
                }
            }
            do {
                let segments = try await Task.detached(priority: .userInitiated) {
                    try await MeetingPlanner.plan(microphone: microphoneURL, system: systemURL, diarizer: diarizer, progress: progress)
                }.value
                guard var planned = store.meeting(id: meetingID) else { return }
                planned.segments = segments
                planned.status = .transcribing
                store.update(planned)
                logger.info("Meeting \(planned.folderName, privacy: .public): \(segments.count, privacy: .public) parts to transcribe")
            } catch {
                fail(meetingID, "Could not read the recording: \(error.localizedDescription)")
                return
            }
        }

        guard let planned = store.meeting(id: meetingID) else { return }
        let pending = planned.segments.filter(\.isPending)
        let promptHint = VocabularyDefaults.buildPromptHint()
        let tracks: [MeetingTrack: URL] = [.microphone: microphoneURL, .system: systemURL]

        await withTaskGroup(of: (UUID, Result<String, Error>).self) { group in
            var remaining = pending.makeIterator()
            func addNext() {
                guard let segment = remaining.next(), let url = tracks[segment.track] else { return }
                group.addTask {
                    (segment.id, await Self.transcribe(segment, trackURL: url, promptHint: promptHint, provider: provider))
                }
            }
            for _ in 0..<maxConcurrentRequests { addNext() }

            for await (segmentID, result) in group {
                // Re-read every time: the user may rename the meeting or a speaker meanwhile.
                if var meeting = store.meeting(id: meetingID),
                   let index = meeting.segments.firstIndex(where: { $0.id == segmentID }) {
                    switch result {
                    case .success(let text):
                        meeting.segments[index].text = text
                    case .failure(let error):
                        meeting.segments[index].error = error.localizedDescription
                        logger.error("Part \(segmentID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    }
                    store.update(meeting)
                }
                addNext()
            }
        }

        guard var finished = store.meeting(id: meetingID) else { return }
        finished.segments = MeetingTranscript.removingEcho(from: finished.segments)
            .filter { $0.error != nil || !($0.text ?? "").isEmpty }
        finished.status = .done
        store.update(finished)

        if finished.failedCount == 0, !MeetingStore.keepsAudio {
            store.deleteAudio(of: finished)
        }
        if finished.segments.isEmpty {
            StatusOverlay.shared.showBrief(message: "No speech found in the meeting recording")
        } else if finished.failedCount == 0 {
            StatusOverlay.shared.showBrief(message: "Meeting transcript ready")
        } else {
            StatusOverlay.shared.showBrief(message: "Meeting transcribed — \(finished.failedCount) parts failed, retry in Meetings")
        }
    }

    private func fail(_ meetingID: UUID, _ reason: String) {
        logger.error("Meeting transcription failed: \(reason, privacy: .public)")
        guard var meeting = store.meeting(id: meetingID) else { return }
        meeting.status = .failed
        meeting.failureReason = reason
        store.update(meeting)
        StatusOverlay.shared.showBrief(message: reason)
    }

    /// Cuts one turn out of its track and transcribes it, retrying network hiccups.
    nonisolated static func transcribe(
        _ segment: MeetingSegment,
        trackURL: URL,
        promptHint: String,
        provider: APIProvider
    ) async -> Result<String, Error> {
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("aihelper-meeting-\(segment.id.uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: clip) }
        do {
            let samples = try MeetingAudio.samples(of: trackURL, from: segment.start, to: segment.end)
            guard !samples.isEmpty else { return .success("") }
            try MeetingAudio.writeM4A(samples, to: clip)
        } catch {
            return .failure(error)
        }

        // On short clips the model can read the prompt back instead of transcribing, so only
        // longer turns get the vocabulary.
        let hint = segment.duration >= 4 ? promptHint : nil
        var attempt = 0
        while true {
            do {
                let result = try await WhisperService.shared.transcribe(audioURL: clip, promptHint: hint, provider: provider)
                return .success(MeetingTranscript.cleaned(result.text, promptHint: hint))
            } catch let error as WhisperError where error.isRetryable && attempt < 2 {
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
            } catch {
                return .failure(error)
            }
        }
    }
}

/// Decides which stretches of which track become transcription requests, and whose they are.
enum MeetingPlanner {
    /// Below this much speech on the system track the meeting counts as in person: everyone
    /// is on the microphone.
    static let minimumCallSpeech: TimeInterval = 3

    static func plan(
        microphone: URL,
        system: URL,
        diarizer: SpeakerDiarizer?,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [MeetingSegment] {
        let segmenter = SpeechSegmenter()
        let fm = FileManager.default
        let microphoneSpeech = fm.fileExists(atPath: microphone.path)
            ? segmenter.speechRanges(in: try MeetingAudio.levels(of: microphone, frameDuration: segmenter.frameDuration))
            : []
        let systemSpeech = fm.fileExists(atPath: system.path)
            ? segmenter.speechRanges(in: try MeetingAudio.levels(of: system, frameDuration: segmenter.frameDuration))
            : []
        let call = isCall(systemSpeech: systemSpeech)

        // On a call the microphone is you, and the system track gets split into the other
        // people; in person everyone is on the microphone, so that is the track to split.
        var microphoneSpeakers: [SpeakerSpan]?
        var systemSpeakers: [SpeakerSpan]?
        if let diarizer {
            do {
                if call {
                    systemSpeakers = try await speakers(in: system, diarizer: diarizer, progress: progress)
                } else if !microphoneSpeech.isEmpty {
                    microphoneSpeakers = try await speakers(in: microphone, diarizer: diarizer, progress: progress)
                }
            } catch {
                logger.error("Speaker separation failed, falling back to Me/Them: \(error.localizedDescription, privacy: .public)")
            }
        }

        return segments(
            microphoneSpeech: microphoneSpeech,
            systemSpeech: call ? systemSpeech : [],
            microphoneSpeakers: microphoneSpeakers,
            systemSpeakers: systemSpeakers
        )
    }

    /// A diarizer that found nobody in a track with speech in it has failed as surely as one
    /// that threw; either way the plain speech ranges are used instead.
    private static func speakers(
        in url: URL,
        diarizer: SpeakerDiarizer,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SpeakerSpan]? {
        let spans = try await diarizer.speakerSpans(in: url, progress: progress)
        guard !spans.isEmpty else {
            logger.error("Speaker separation found no speech in \(url.lastPathComponent, privacy: .public), falling back to Me/Them")
            return nil
        }
        return MeetingTurns.numberingSpeakers(spans)
    }

    /// A single voice on the microphone is whoever is recording — "Me", not "Speaker 1". That
    /// is also what a call looks like when nobody else has spoken yet.
    private static func soleVoiceIsMe(_ spans: [SpeakerSpan]) -> [SpeakerSpan] {
        guard Set(spans.map(\.speaker)).count == 1 else { return spans }
        return spans.map { SpeakerSpan(speaker: MeetingSpeaker.me, start: $0.start, end: $0.end) }
    }

    static func isCall(systemSpeech: [ClosedRange<TimeInterval>]) -> Bool {
        systemSpeech.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } >= minimumCallSpeech
    }

    /// The transcription requests for both tracks, in time order. Speaker spans from a diarizer
    /// replace the plain speech ranges of their track; without them the microphone is "Me" and
    /// the system track "Them".
    static func segments(
        microphoneSpeech: [ClosedRange<TimeInterval>],
        systemSpeech: [ClosedRange<TimeInterval>],
        microphoneSpeakers: [SpeakerSpan]? = nil,
        systemSpeakers: [SpeakerSpan]? = nil
    ) -> [MeetingSegment] {
        let microphone = microphoneSpeakers.map(soleVoiceIsMe)
            ?? microphoneSpeech.map { SpeakerSpan(speaker: MeetingSpeaker.me, start: $0.lowerBound, end: $0.upperBound) }
        let system = systemSpeakers
            ?? systemSpeech.map { SpeakerSpan(speaker: MeetingSpeaker.them, start: $0.lowerBound, end: $0.upperBound) }

        let segments = MeetingTurns.turns(from: microphone).map {
            MeetingSegment(track: .microphone, speaker: $0.speaker, start: $0.start, end: $0.end)
        } + MeetingTurns.turns(from: system).map {
            MeetingSegment(track: .system, speaker: $0.speaker, start: $0.start, end: $0.end)
        }
        return segments.sorted { $0.start < $1.start }
    }
}
