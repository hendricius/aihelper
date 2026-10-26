import XCTest
@testable import AIHelper

final class SpeechSegmenterTests: XCTestCase {

    private let segmenter = SpeechSegmenter()

    /// Per-frame levels for a made-up track: each part is a loudness held for some seconds.
    private func levels(_ parts: [(level: Float, seconds: Double)]) -> [Float] {
        parts.flatMap { Array(repeating: $0.level, count: Int(($0.seconds / segmenter.frameDuration).rounded())) }
    }

    func testSilentTrackHasNoSpeech() {
        XCTAssertEqual(segmenter.speechRanges(in: []), [])
        XCTAssertEqual(segmenter.speechRanges(in: levels([(0, 10)])), [])
    }

    func testFindsSpeechBetweenSilenceWithPadding() {
        let ranges = segmenter.speechRanges(in: levels([(0.001, 2), (0.1, 3), (0.001, 2)]))

        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].lowerBound, 2 - segmenter.padding, accuracy: 0.05)
        XCTAssertEqual(ranges[0].upperBound, 5 + segmenter.padding, accuracy: 0.05)
    }

    func testShortPauseKeepsOneTurn() {
        let ranges = segmenter.speechRanges(in: levels([(0.001, 1), (0.1, 2), (0.001, 0.5), (0.1, 2), (0.001, 1)]))
        XCTAssertEqual(ranges.count, 1)
    }

    func testLongPauseSplitsTurns() {
        let ranges = segmenter.speechRanges(in: levels([(0.001, 1), (0.1, 2), (0.001, 2), (0.1, 2), (0.001, 1)]))
        XCTAssertEqual(ranges.count, 2)
    }

    func testIgnoresClicks() {
        let ranges = segmenter.speechRanges(in: levels([(0.001, 2), (0.2, 0.09), (0.001, 2)]))
        XCTAssertEqual(ranges, [])
    }

    func testThresholdFollowsTheNoiseFloor() {
        // A noisy room at 0.02 RMS is not speech; talking over it at 0.15 is.
        let ranges = segmenter.speechRanges(in: levels([(0.02, 5), (0.15, 3), (0.02, 5)]))

        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].lowerBound, 5 - segmenter.padding, accuracy: 0.05)
    }

    func testSplitsAMonologueAtItsQuietestMoment() {
        // 100 s without a pause, a slightly softer syllable 30 s in.
        var speech = levels([(0.1, 100)])
        speech[Int(30 / segmenter.frameDuration)] = 0.06
        let ranges = segmenter.speechRanges(in: levels([(0.001, 15)]) + speech + levels([(0.001, 15)]))

        XCTAssertGreaterThanOrEqual(ranges.count, 3)
        XCTAssertTrue(ranges.allSatisfy { $0.upperBound - $0.lowerBound <= segmenter.maxLength + 0.01 })
        XCTAssertEqual(ranges[0].upperBound, 45, accuracy: 0.05, "cut at the soft syllable")
        XCTAssertEqual(ranges.last?.upperBound ?? 0, 115 + segmenter.padding, accuracy: 0.05)
    }
}
