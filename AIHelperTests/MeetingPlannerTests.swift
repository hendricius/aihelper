import AVFoundation
import XCTest
@testable import AIHelper

/// The planner end to end on real track files, with a stand-in diarizer.
final class MeetingPlannerTests: XCTestCase {

    private struct StubDiarizer: SpeakerDiarizer {
        var spans: [SpeakerSpan] = []
        var fails = false

        func speakerSpans(in url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeakerSpan] {
            if fails { throw CocoaError(.fileReadCorruptFile) }
            return spans
        }
    }

    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aihelper-tests-planner-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        folder = nil
        super.tearDown()
    }

    /// A 16 kHz track of `duration` seconds, silent except for a tone during `speech`.
    private func track(_ name: String, duration: TimeInterval, speech: [ClosedRange<TimeInterval>]) throws -> URL {
        let rate = MeetingTrackWriter.sampleRate
        let frames = Int(duration * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: MeetingTrackWriter.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = buffer.floatChannelData![0]
        for index in 0..<frames {
            let time = Double(index) / rate
            samples[index] = speech.contains { $0.contains(time) } ? 0.3 * Float(sin(2 * Double.pi * 220 * time)) : 0
        }

        let url = folder.appendingPathComponent(name)
        let writer = try MeetingTrackWriter(url: url, clock: { duration })
        writer.append(buffer)
        writer.finish()
        return url
    }

    func testCallSpeakersComeFromTheDiarizer() async throws {
        let microphone = try track("microphone.caf", duration: 12, speech: [4.5...5.5])
        let system = try track("system.caf", duration: 12, speech: [1...4, 6...9])
        let diarizer = StubDiarizer(spans: [
            SpeakerSpan(speaker: "B", start: 6, end: 9),
            SpeakerSpan(speaker: "A", start: 1, end: 4),
        ])

        let segments = try await MeetingPlanner.plan(microphone: microphone, system: system, diarizer: diarizer)

        XCTAssertEqual(segments.map(\.speaker), ["speaker-1", MeetingSpeaker.me, "speaker-2"])
        XCTAssertEqual(segments.map(\.track), [.system, .microphone, .system])
    }

    func testWithoutADiarizerTheCallIsThem() async throws {
        let microphone = try track("microphone.caf", duration: 12, speech: [4.5...5.5])
        let system = try track("system.caf", duration: 12, speech: [1...4, 6...9])

        let segments = try await MeetingPlanner.plan(microphone: microphone, system: system, diarizer: nil)

        XCTAssertEqual(segments.map(\.speaker), [MeetingSpeaker.them, MeetingSpeaker.me, MeetingSpeaker.them])
    }

    func testADiarizerThatFindsNobodyFallsBackToThem() async throws {
        let microphone = try track("microphone.caf", duration: 12, speech: [])
        let system = try track("system.caf", duration: 12, speech: [1...4, 6...9])

        let segments = try await MeetingPlanner.plan(microphone: microphone, system: system, diarizer: StubDiarizer())

        XCTAssertEqual(segments.map(\.speaker), [MeetingSpeaker.them, MeetingSpeaker.them])
    }

    func testAFailingDiarizerFallsBackToThem() async throws {
        let microphone = try track("microphone.caf", duration: 12, speech: [])
        let system = try track("system.caf", duration: 12, speech: [1...4, 6...9])
        let diarizer = StubDiarizer(fails: true)

        let segments = try await MeetingPlanner.plan(microphone: microphone, system: system, diarizer: diarizer)

        XCTAssertEqual(segments.map(\.speaker), [MeetingSpeaker.them, MeetingSpeaker.them])
    }

    func testInPersonTheMicrophoneIsSplitIntoSpeakers() async throws {
        let microphone = try track("microphone.caf", duration: 12, speech: [1...4, 6...9])
        let system = try track("system.caf", duration: 12, speech: [])
        let diarizer = StubDiarizer(spans: [
            SpeakerSpan(speaker: "x", start: 1, end: 4),
            SpeakerSpan(speaker: "y", start: 6, end: 9),
        ])

        let segments = try await MeetingPlanner.plan(microphone: microphone, system: system, diarizer: diarizer)

        XCTAssertEqual(segments.map(\.speaker), ["speaker-1", "speaker-2"])
        XCTAssertEqual(segments.map(\.track), [.microphone, .microphone])
    }
}
