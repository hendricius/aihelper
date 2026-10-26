import AVFoundation
import XCTest
@testable import AIHelper

final class MeetingAudioTests: XCTestCase {

    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aihelper-tests-meeting-audio-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        folder = nil
        super.tearDown()
    }

    private func tone(seconds: Double, sampleRate: Double, channels: AVAudioChannelCount, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for index in 0..<Int(frames) {
                buffer.floatChannelData![channel][index] = amplitude * sin(2 * .pi * 440 * Float(index) / Float(sampleRate))
            }
        }
        return buffer
    }

    func testWriterStoresSixteenKilohertzMonoWhateverComesIn() throws {
        var now: TimeInterval = 0
        let url = folder.appendingPathComponent("track.caf")
        let writer = try MeetingTrackWriter(url: url, clock: { now })

        // Two seconds of 48 kHz stereo, in 100 ms buffers arriving on time.
        for _ in 0..<20 {
            now += 0.1
            writer.append(tone(seconds: 0.1, sampleRate: 48_000, channels: 2))
        }

        XCTAssertEqual(writer.finish(), 2.0, accuracy: 0.05)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(MeetingAudio.duration(of: url), 2.0, accuracy: 0.05)
    }

    func testWriterBridgesAStallWithSilence() throws {
        var now: TimeInterval = 0
        let url = folder.appendingPathComponent("track.caf")
        let writer = try MeetingTrackWriter(url: url, clock: { now })

        now = 1
        writer.append(tone(seconds: 1, sampleRate: 16_000, channels: 1))   // 0–1 s
        now = 4
        writer.append(tone(seconds: 1, sampleRate: 16_000, channels: 1))   // after a 2 s stall: 3–4 s

        XCTAssertEqual(writer.finish(), 4.0, accuracy: 0.01)
        let levels = try MeetingAudio.levels(of: url, frameDuration: 0.1)
        XCTAssertEqual(levels.count, 40)
        XCTAssertGreaterThan(levels[5], 0.1, "tone at 0.5 s")
        XCTAssertEqual(levels[20], 0, accuracy: 0.001, "silence at 2.0 s")
        XCTAssertGreaterThan(levels[35], 0.1, "tone at 3.5 s, back on the shared timeline")
    }

    func testSamplesCutsTheRequestedStretch() throws {
        var now: TimeInterval = 0
        let url = folder.appendingPathComponent("track.caf")
        let writer = try MeetingTrackWriter(url: url, clock: { now })
        now = 1
        writer.append(tone(seconds: 1, sampleRate: 16_000, channels: 1, amplitude: 0))
        now = 2
        writer.append(tone(seconds: 1, sampleRate: 16_000, channels: 1))
        writer.finish()

        let quiet = try MeetingAudio.samples(of: url, from: 0.2, to: 0.7)
        let loud = try MeetingAudio.samples(of: url, from: 1.0, to: 2.0)

        XCTAssertEqual(quiet.count, 8_000)
        XCTAssertEqual(quiet.map(abs).max() ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(loud.count, 16_000)
        XCTAssertGreaterThan(loud.map(abs).max() ?? 0, 0.4)
        XCTAssertEqual(try MeetingAudio.samples(of: url, from: 5, to: 6), [], "past the end")
    }

    func testClipsAreWrittenAsReadableM4A() throws {
        let samples = (0..<16_000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 16_000)) * 0.5 }
        let url = folder.appendingPathComponent("clip.m4a")

        try MeetingAudio.writeM4A(samples, to: url)

        XCTAssertEqual(MeetingAudio.duration(of: url), 1.0, accuracy: 0.1)
    }
}
