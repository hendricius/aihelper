import AVFoundation
import XCTest
@testable import AIHelper

/// Runs the real FluidAudio models on two synthetic voices taking turns. Opt-in, because the
/// first run downloads the models from Hugging Face:
///
///     TEST_RUNNER_AIHELPER_DIARIZATION_SMOKE=1 xcodebuild test -project AIHelper.xcodeproj \
///         -scheme AIHelper -destination 'platform=macOS' \
///         -only-testing:AIHelperTests/SpeakerDiarizationSmokeTests
///
/// Add `TEST_RUNNER_AIHELPER_DIARIZATION_SMOKE_REPEAT=20` to lay the conversation out 20 times
/// (about 12 minutes) and read the timing from the log for a long meeting.
final class SpeakerDiarizationSmokeTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AIHELPER_DIARIZATION_SMOKE"] == "1",
                          "Set TEST_RUNNER_AIHELPER_DIARIZATION_SMOKE=1 to run the real diarization models")
        try XCTSkipUnless(FluidAudioDiarizer.isSupported, "Speaker separation needs macOS 15")
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aihelper-tests-diarization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }

    private func speak(_ text: String, voice: String) throws -> AVAudioPCMBuffer {
        let url = folder.appendingPathComponent("\(UUID().uuidString).aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "-o", url.path, text]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0, "say -v \(voice)")

        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return buffer
    }

    func testTwoVoicesComeOutAsTwoSpeakers() async throws {
        let turns: [(voice: String, text: String)] = [
            ("Samantha", "Good morning everyone. Let's go through the launch plan for the new pricing page and see where we stand."),
            ("Daniel", "Thanks. The design is finished, but the copy still needs a review from the legal team before Friday."),
            ("Samantha", "Understood. Can you send it to them today, so we keep the date for the announcement next week?"),
            ("Daniel", "Yes, I will send it this afternoon and let you know as soon as they have signed it off."),
        ]

        let clips = try turns.map { try speak($0.text, voice: $0.voice) }
        let repeats = max(1, Int(ProcessInfo.processInfo.environment["AIHELPER_DIARIZATION_SMOKE_REPEAT"] ?? "") ?? 1)

        // Lay the turns out on one track the way a call would: each voice, then a short pause.
        var now: TimeInterval = 0
        var expected: [(voice: String, range: ClosedRange<TimeInterval>)] = []
        let url = folder.appendingPathComponent("system.caf")
        let writer = try MeetingTrackWriter(url: url, clock: { now })
        for _ in 0..<repeats {
            for (turn, buffer) in zip(turns, clips) {
                let length = Double(buffer.frameLength) / buffer.format.sampleRate
                now += 0.8 + length
                expected.append((turn.voice, (now - length)...now))
                writer.append(buffer)
            }
        }
        writer.finish()

        let spans = try await FluidAudioDiarizer().speakerSpans(in: url) { _ in }

        // Whoever the diarizer says holds the middle of each turn.
        func speaker(at time: TimeInterval) -> String? {
            spans.first { $0.start <= time && time <= $0.end }?.speaker
        }
        let labels = expected.map { speaker(at: ($0.range.lowerBound + $0.range.upperBound) / 2) }
        XCTAssertFalse(labels.contains(nil), "every turn has a speaker: \(spans)")
        let samantha = Set(zip(expected, labels).filter { $0.0.voice == "Samantha" }.compactMap(\.1))
        let daniel = Set(zip(expected, labels).filter { $0.0.voice == "Daniel" }.compactMap(\.1))
        XCTAssertEqual(samantha.count, 1, "Samantha is always the same speaker")
        XCTAssertEqual(daniel.count, 1, "Daniel is always the same speaker")
        XCTAssertTrue(samantha.isDisjoint(with: daniel), "Samantha and Daniel told apart")
    }
}
