import FluidAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "SpeakerDiarization")

/// Tells voices apart on the Mac with FluidAudio's offline pipeline: pyannote segmentation,
/// WeSpeaker embeddings and VBx clustering, running on the Neural Engine. No audio leaves the
/// Mac for this step. The Core ML models download from Hugging Face the first time (into
/// ~/Library/Application Support/FluidAudio/Models) and load from there afterwards.
struct FluidAudioDiarizer: SpeakerDiarizer {
    /// UserDefaults key: tell speakers apart (on unless switched off).
    static let enabledKey = "meetings.separateSpeakers"

    /// macOS 14 has an Apple Core ML (BNNS) bug that can crash this pipeline outright, in a way
    /// no error handling catches (FluidAudio issue #878). Apple fixed it in macOS 15.
    static var isSupported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// The diarizer for the next meeting; nil when switched off or unsupported, and the
    /// transcript then says "Me" and "Them".
    static var current: SpeakerDiarizer? {
        isSupported && isEnabled ? FluidAudioDiarizer() : nil
    }

    func speakerSpans(in url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeakerSpan] {
        // Loaded per meeting and released afterwards, so a menu-bar app that runs all day does
        // not keep the models in memory between meetings.
        let started = Date()
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels()
        let loaded = Date()
        let result = try await manager.process(url) { done, total in
            if total > 0 { progress(Double(done) / Double(total)) }
        }

        let spans = result.segments.map {
            SpeakerSpan(speaker: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds))
        }
        let loading = loaded.timeIntervalSince(started), processing = Date().timeIntervalSince(loaded)
        logger.info("\(url.lastPathComponent, privacy: .public): \(Set(spans.map(\.speaker)).count, privacy: .public) speakers in \(spans.count, privacy: .public) stretches (models \(loading, format: .fixed(precision: 1), privacy: .public)s, audio \(processing, format: .fixed(precision: 1), privacy: .public)s)")
        return spans
    }
}
