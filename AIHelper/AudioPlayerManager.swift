import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "AudioPlayerManager")

@MainActor
class AudioPlayerManager: NSObject, ObservableObject {
    static let shared = AudioPlayerManager()

    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var currentTranscriptionId: UUID?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    override init() {
        super.init()
    }

    func play(fileName: String, transcriptionId: UUID) {
        guard let url = AudioFileManager.audioURL(for: fileName) else {
            logger.warning("Audio file not found: \(fileName)")
            return
        }

        // Stop current playback if different
        if isPlaying {
            stop()
        }

        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer.delegate = self
            audioPlayer.prepareToPlay()
            audioPlayer.play()

            player = audioPlayer
            isPlaying = true
            duration = audioPlayer.duration
            currentTime = 0
            currentTranscriptionId = transcriptionId

            startTimer()
            logger.info("Playing audio: \(fileName)")
        } catch {
            logger.error("Failed to play audio: \(error.localizedDescription)")
        }
    }

    func stop() {
        stopTimer()
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        currentTranscriptionId = nil
    }

    func togglePlayPause(fileName: String, transcriptionId: UUID) {
        if isPlaying && currentTranscriptionId == transcriptionId {
            stop()
        } else {
            play(fileName: fileName, transcriptionId: transcriptionId)
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

extension AudioPlayerManager: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            logger.debug("Audio playback finished")
            self.stop()
        }
    }
}
