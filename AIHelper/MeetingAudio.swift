import Accelerate
import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "MeetingAudio")

/// Writes one meeting track to disk as 16 kHz mono 16-bit PCM, whatever format the source
/// delivers, and keeps it on the shared timeline: when the source stalls (a device switch
/// restarts the microphone, the system tap is rebuilt) the gap is filled with silence, so
/// second 90 of the microphone track and second 90 of the system track are the same moment.
final class MeetingTrackWriter {
    static let sampleRate: Double = 16_000
    static let processingFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
    )!

    let url: URL
    /// Seconds since the recording started; injectable for tests.
    private let clock: () -> TimeInterval
    private let queue: DispatchQueue
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var framesWritten: AVAudioFramePosition = 0
    /// Stalls shorter than this are scheduling jitter, not gaps.
    private let gapTolerance: TimeInterval = 0.5

    init(url: URL, clock: @escaping () -> TimeInterval) throws {
        self.url = url
        self.clock = clock
        self.queue = DispatchQueue(label: "com.aihelper.meeting-writer.\(url.deletingPathExtension().lastPathComponent)")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Copies `buffer` and writes it on the writer's own queue. Safe to call from audio threads;
    /// the buffer does not need to outlive the call.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let copy = buffer.copiedBuffer() else { return }
        let arrival = clock()
        queue.async { [weak self] in self?.write(copy, arrivedAt: arrival) }
    }

    /// Waits for pending writes and closes the file. Returns the track's length in seconds.
    @discardableResult
    func finish() -> TimeInterval {
        queue.sync {
            file = nil  // closing the AVAudioFile finalises the header
            converter = nil
            return Double(framesWritten) / Self.sampleRate
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer, arrivedAt arrival: TimeInterval) {
        guard let file else { return }
        guard let converted = convert(buffer), converted.frameLength > 0 else { return }

        // The buffer ends roughly when it arrived; anything between the end of what was written
        // and its start is a stall to bridge with silence.
        let expectedStart = AVAudioFramePosition(arrival * Self.sampleRate) - AVAudioFramePosition(converted.frameLength)
        let gap = expectedStart - framesWritten
        if gap > AVAudioFramePosition(gapTolerance * Self.sampleRate) {
            writeSilence(frames: gap)
        }

        do {
            try file.write(from: converted)
            framesWritten += AVAudioFramePosition(converted.frameLength)
        } catch {
            logger.error("Writing \(self.url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == Self.processingFormat { return buffer }

        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.processingFormat)
            converter?.downmix = true
        }
        guard let converter else { return nil }

        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.processingFormat, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            logger.error("Converting audio failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }
        return output
    }

    private func writeSilence(frames: AVAudioFramePosition) {
        let chunk = AVAudioFrameCount(Self.sampleRate)
        guard let file, let silence = AVAudioPCMBuffer(pcmFormat: Self.processingFormat, frameCapacity: chunk),
              let channel = silence.floatChannelData?[0] else { return }
        channel.initialize(repeating: 0, count: Int(chunk))

        var remaining = frames
        while remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(chunk)))
            silence.frameLength = count
            do {
                try file.write(from: silence)
            } catch {
                logger.error("Writing silence failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            framesWritten += AVAudioFramePosition(count)
            remaining -= AVAudioFramePosition(count)
        }
        logger.info("Bridged a \(Double(frames) / Self.sampleRate, privacy: .public)s gap in \(self.url.lastPathComponent, privacy: .public)")
    }
}

/// Reading back and cutting up recorded meeting tracks.
enum MeetingAudio {
    /// RMS level of every `frameDuration` slice of a track — the input for `SpeechSegmenter`.
    /// Streams through the file, so a long meeting never sits in memory.
    static func levels(of url: URL, frameDuration: TimeInterval = 0.03) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frameLength = max(1, Int(frameDuration * file.processingFormat.sampleRate))
        let chunkFrames = AVAudioFrameCount(frameLength * 1000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else { return [] }

        var levels: [Float] = []
        levels.reserveCapacity(Int(file.length) / frameLength + 1)
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunkFrames)
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
            var offset = 0
            while offset < Int(buffer.frameLength) {
                let count = min(frameLength, Int(buffer.frameLength) - offset)
                var rms: Float = 0
                vDSP_rmsqv(channel + offset, 1, &rms, vDSP_Length(count))
                levels.append(rms)
                offset += count
            }
        }
        return levels
    }

    /// The samples between two moments of a track (first channel, at the file's sample rate).
    static func samples(of url: URL, from start: TimeInterval, to end: TimeInterval) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        let first = max(0, min(file.length, AVAudioFramePosition(start * rate)))
        let last = max(first, min(file.length, AVAudioFramePosition(end * rate)))
        let count = AVAudioFrameCount(last - first)
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return [] }
        file.framePosition = first
        try file.read(into: buffer, frameCount: count)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// Length of a track in seconds; 0 when it cannot be read.
    static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Encodes samples as a small AAC file — the format the transcription upload expects.
    static func writeM4A(_ samples: [Float], sampleRate: Double = MeetingTrackWriter.sampleRate, to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        // The file is finalised when it goes out of scope at the end of this function.
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}

extension AVAudioPCMBuffer {
    /// A deep copy, so audio handed over by a capture callback can outlive the callback.
    func copiedBuffer() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}
