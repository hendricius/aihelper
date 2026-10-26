import XCTest
@testable import AIHelper

final class MeetingTranscriptTests: XCTestCase {

    private func segment(_ track: MeetingTrack, _ speaker: String, _ start: TimeInterval, _ end: TimeInterval, _ text: String?) -> MeetingSegment {
        var segment = MeetingSegment(track: track, speaker: speaker, start: start, end: end)
        segment.text = text
        return segment
    }

    private func meeting(_ segments: [MeetingSegment]) -> Meeting {
        var meeting = Meeting(title: "Weekly sync", startedAt: Date(timeIntervalSince1970: 1_800_000_000), folderName: "test")
        meeting.duration = 600
        meeting.status = .done
        meeting.segments = segments
        return meeting
    }

    // MARK: - Turns

    func testTurnsJoinCloseSpansOfOneSpeaker() {
        let turns = MeetingTurns.turns(from: [
            SpeakerSpan(speaker: "a", start: 0, end: 2),
            SpeakerSpan(speaker: "a", start: 2.5, end: 4),
            SpeakerSpan(speaker: "b", start: 4.2, end: 6),
            SpeakerSpan(speaker: "a", start: 6.1, end: 8),
        ])

        XCTAssertEqual(turns, [
            SpeakerSpan(speaker: "a", start: 0, end: 4),
            SpeakerSpan(speaker: "b", start: 4.2, end: 6),
            SpeakerSpan(speaker: "a", start: 6.1, end: 8),
        ])
    }

    func testTurnsSplitLongSpansAndDropBlips() {
        let turns = MeetingTurns.turns(from: [
            SpeakerSpan(speaker: "a", start: 0, end: 100),
            SpeakerSpan(speaker: "b", start: 120, end: 120.3),
        ])

        XCTAssertEqual(turns.count, 3)
        XCTAssertTrue(turns.allSatisfy { $0.speaker == "a" && $0.duration <= 45 })
        XCTAssertEqual(turns.first?.start, 0)
        XCTAssertEqual(turns.last?.end, 100)
    }

    func testDiarizerLabelsAreNumberedByFirstAppearance() {
        let spans = MeetingTurns.numberingSpeakers([
            SpeakerSpan(speaker: "SPK_7", start: 5, end: 6),
            SpeakerSpan(speaker: "SPK_2", start: 0, end: 1),
            SpeakerSpan(speaker: "SPK_7", start: 9, end: 10),
        ])

        XCTAssertEqual(spans.map(\.speaker), ["speaker-1", "speaker-2", "speaker-2"])
        XCTAssertEqual(spans.map(\.start), [0, 5, 9])
    }

    func testDefaultSpeakerNames() {
        XCTAssertEqual(MeetingSpeaker.defaultName(for: MeetingSpeaker.me), "Me")
        XCTAssertEqual(MeetingSpeaker.defaultName(for: MeetingSpeaker.them), "Them")
        XCTAssertEqual(MeetingSpeaker.defaultName(for: MeetingSpeaker.numbered(12)), "Speaker 12")
    }

    // MARK: - Planner

    func testPlannerLabelsTheTracksMeAndThem() {
        let segments = MeetingPlanner.segments(microphoneSpeech: [0...4, 10...12], systemSpeech: [4.5...9])

        XCTAssertEqual(segments.map(\.speaker), [MeetingSpeaker.me, MeetingSpeaker.them, MeetingSpeaker.me])
        XCTAssertEqual(segments.map(\.track), [.microphone, .system, .microphone])
    }

    func testPlannerUsesDiarizedSpeakersForTheCall() {
        let segments = MeetingPlanner.segments(
            microphoneSpeech: [0...3],
            systemSpeech: [4...12],
            systemSpeakers: [
                SpeakerSpan(speaker: "speaker-1", start: 4, end: 7),
                SpeakerSpan(speaker: "speaker-2", start: 7.5, end: 12),
            ]
        )

        XCTAssertEqual(segments.map(\.speaker), [MeetingSpeaker.me, "speaker-1", "speaker-2"])
    }

    func testABriefSoundOnTheSystemTrackIsNotACall() {
        XCTAssertFalse(MeetingPlanner.isCall(systemSpeech: [0...1.5]))
        XCTAssertTrue(MeetingPlanner.isCall(systemSpeech: [0...2, 5...7]))
    }

    // MARK: - Transcript

    func testConsecutiveTurnsOfOneSpeakerFormOneParagraph() {
        let paragraphs = MeetingTranscript.paragraphs(for: meeting([
            segment(.microphone, MeetingSpeaker.me, 0, 3, "Hi everyone."),
            segment(.microphone, MeetingSpeaker.me, 4, 6, "Let's start."),
            segment(.system, MeetingSpeaker.them, 7, 9, "Sounds good."),
            segment(.microphone, MeetingSpeaker.me, 10, 12, "Great."),
        ]))

        XCTAssertEqual(paragraphs.map(\.text), ["Hi everyone. Let's start.", "Sounds good.", "Great."])
        XCTAssertEqual(paragraphs.map(\.start), [0, 7, 10])
    }

    func testALongSilenceStartsANewParagraph() {
        let paragraphs = MeetingTranscript.paragraphs(for: meeting([
            segment(.microphone, MeetingSpeaker.me, 0, 3, "One."),
            segment(.microphone, MeetingSpeaker.me, 20, 22, "Two."),
        ]))

        XCTAssertEqual(paragraphs.map(\.text), ["One.", "Two."])
    }

    func testEmptyAndFailedPartsAreLeftOut() {
        var failed = segment(.system, MeetingSpeaker.them, 5, 6, nil)
        failed.error = "Network error"
        let transcribed = meeting([
            segment(.microphone, MeetingSpeaker.me, 0, 2, ""),
            failed,
            segment(.system, MeetingSpeaker.them, 8, 9, "Hello?"),
        ])

        XCTAssertEqual(MeetingTranscript.text(for: transcribed), "[00:08] Them: Hello?")
        XCTAssertEqual(transcribed.speakers, [MeetingSpeaker.them])
        XCTAssertEqual(transcribed.failedCount, 1)
    }

    func testTranscriptUsesRenamedSpeakers() {
        var renamed = meeting([
            segment(.microphone, MeetingSpeaker.me, 65, 67, "Hello."),
            segment(.system, MeetingSpeaker.numbered(2), 70, 72, "Hi!"),
        ])
        renamed.speakerNames = [MeetingSpeaker.me: "Hendrik"]

        XCTAssertEqual(MeetingTranscript.text(for: renamed), "[01:05] Hendrik: Hello.\n\n[01:10] Speaker 2: Hi!")
    }

    func testMarkdownHasTitleLengthAndSpeakers() {
        let markdown = MeetingTranscript.markdown(for: meeting([
            segment(.microphone, MeetingSpeaker.me, 0, 2, "Hi."),
            segment(.system, MeetingSpeaker.them, 3, 4, "Hey."),
        ]))

        XCTAssertTrue(markdown.hasPrefix("# Weekly sync\n"))
        XCTAssertTrue(markdown.contains("10 min · Me, Them"))
        XCTAssertTrue(markdown.contains("[00:03] Them: Hey."))
    }

    func testTimestamps() {
        XCTAssertEqual(MeetingTranscript.timestamp(0), "00:00")
        XCTAssertEqual(MeetingTranscript.timestamp(65.9), "01:05")
        XCTAssertEqual(MeetingTranscript.timestamp(3723), "1:02:03")
    }

    // MARK: - Echo and prompt read-back

    func testEchoOfTheCallIsRemovedFromTheMicrophone() {
        let kept = MeetingTranscript.removingEcho(from: [
            segment(.system, MeetingSpeaker.them, 10, 14, "Can everyone see the proposal on my screen?"),
            segment(.microphone, MeetingSpeaker.me, 10.2, 14.1, "can everyone see the proposal on my screen"),
            segment(.microphone, MeetingSpeaker.me, 15, 17, "Yes, I can see it."),
        ])

        XCTAssertEqual(kept.compactMap(\.text), ["Can everyone see the proposal on my screen?", "Yes, I can see it."])
    }

    func testOwnSpeechOverlappingTheCallIsKept() {
        let kept = MeetingTranscript.removingEcho(from: [
            segment(.system, MeetingSpeaker.them, 10, 14, "Let's move the launch to Tuesday."),
            segment(.microphone, MeetingSpeaker.me, 12, 14, "Sorry, which date was that?"),
        ])

        XCTAssertEqual(kept.count, 2)
    }

    func testPromptReadBackIsDropped() {
        let hint = "Terms: Kubernetes, AIHelper, Allonsy"

        XCTAssertEqual(MeetingTranscript.cleaned("Kubernetes, AIHelper", promptHint: hint), "")
        XCTAssertEqual(MeetingTranscript.cleaned(" We ship AIHelper on Friday. ", promptHint: hint), "We ship AIHelper on Friday.")
        XCTAssertEqual(MeetingTranscript.cleaned("Terms: Kubernetes", promptHint: nil), "Terms: Kubernetes")
    }
}
