import Foundation

/// Finds where someone is talking in a track from its short-term loudness.
///
/// Works on per-frame RMS levels (see `MeetingAudio.levels(of:frameDuration:)`) rather than
/// on samples, so an hour of meeting is about 120,000 numbers instead of 57 million. Energy is
/// a crude speech detector, but each track here has a single, clean source: a close
/// microphone, or the Mac's own output, which is digital silence between sentences.
struct SpeechSegmenter {
    var frameDuration: TimeInterval = 0.03
    /// Bursts with less voiced time than this are clicks, coughs and keyboard noise.
    var minSpeech: TimeInterval = 0.3
    /// A pause at least this long ends a turn.
    var maxPause: TimeInterval = 0.8
    /// Kept before and after each turn so the first and last syllables are not clipped.
    var padding: TimeInterval = 0.25
    /// Turns longer than this are split at their quietest moment.
    var maxLength: TimeInterval = 45
    /// A frame is speech when it is this many times louder than the track's noise floor…
    var noiseFactor: Float = 4
    /// …and at least this loud (RMS ≈ -46 dBFS), so a silent track yields nothing.
    var minimumLevel: Float = 0.005

    /// The speech stretches in a track, in seconds from its start.
    func speechRanges(in levels: [Float]) -> [ClosedRange<TimeInterval>] {
        guard !levels.isEmpty else { return [] }
        let threshold = max(noiseFloor(of: levels) * noiseFactor, minimumLevel)

        // Runs of loud frames, joined across pauses shorter than `maxPause`.
        let maxPauseFrames = frames(maxPause)
        var runs: [(start: Int, end: Int, voiced: Int)] = []
        for (index, level) in levels.enumerated() where level >= threshold {
            if let last = runs.last, index - last.end <= maxPauseFrames {
                runs[runs.count - 1] = (last.start, index + 1, last.voiced + 1)
            } else {
                runs.append((index, index + 1, 1))
            }
        }

        let minSpeechFrames = frames(minSpeech)
        let paddingFrames = frames(padding)
        var padded: [(start: Int, end: Int)] = []
        for run in runs where run.voiced >= minSpeechFrames {
            let start = max(0, run.start - paddingFrames)
            let end = min(levels.count, run.end + paddingFrames)
            if let last = padded.last, start <= last.end {
                padded[padded.count - 1].end = max(last.end, end)
            } else {
                padded.append((start, end))
            }
        }

        return padded
            .flatMap { splitLong($0, levels: levels) }
            .map { TimeInterval($0.start) * frameDuration...TimeInterval($0.end) * frameDuration }
    }

    /// The level the quietest tenth of the track stays under: room noise for a microphone,
    /// zero for the system track.
    func noiseFloor(of levels: [Float]) -> Float {
        let sorted = levels.sorted()
        return sorted[min(sorted.count - 1, sorted.count / 10)]
    }

    private func frames(_ seconds: TimeInterval) -> Int {
        max(1, Int((seconds / frameDuration).rounded()))
    }

    /// Splits a run longer than `maxLength` at the quietest frame in the back half of each
    /// window, so a monologue is cut between words rather than mid-word.
    private func splitLong(_ run: (start: Int, end: Int), levels: [Float]) -> [(start: Int, end: Int)] {
        let maxFrames = frames(maxLength)
        var parts: [(start: Int, end: Int)] = []
        var start = run.start
        while run.end - start > maxFrames {
            let window = (start + maxFrames / 2)..<(start + maxFrames)
            let cut = window.min { levels[$0] < levels[$1] } ?? (start + maxFrames)
            parts.append((start, cut))
            start = cut
        }
        parts.append((start, run.end))
        return parts
    }
}
