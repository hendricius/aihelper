import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "AudioRecorder")

@MainActor
class AudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var recordingTime: TimeInterval = 0
    @Published private(set) var lastError: RecordingError?

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var timer: Timer?
    private var recordingURL: URL?
    private var recordingStartTime: Date?

    // Stop word detection
    private var stopWordDetector: StopWordDetector?
    private var stopWordDetectionEnabled = false

    /// Callback when stop word is detected during recording
    var onStopWordDetected: (() -> Void)?

    // Recording format for AAC output
    private var outputFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }

    override init() {
        super.init()
        logger.info("AudioRecorder initialized (AVAudioEngine-based)")
    }

    deinit {
        timer?.invalidate()
        logger.debug("AudioRecorder deinitialized")
    }

    // MARK: - Public Methods

    func startRecording(withStopWordDetection: Bool = false) throws {
        logger.info("Starting recording (stopWordDetection: \(withStopWordDetection))...")

        // Clear any previous error
        lastError = nil

        // Stop any existing recording first
        if isRecording {
            logger.warning("Already recording, stopping previous recording")
            _ = stopRecording()
        }

        // Create recording URL
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "recording_\(Date().timeIntervalSince1970).m4a"
        let url = tempDir.appendingPathComponent(fileName)
        recordingURL = url

        logger.debug("Recording to: \(url.path)")

        do {
            // Set up audio engine
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode

            // Get the native format of the input node
            let inputFormat = inputNode.outputFormat(forBus: 0)
            logger.debug("Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channels")

            // Create audio file for recording
            // We'll use WAV format for better compatibility, then convert can happen later if needed
            let fileSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            let file = try AVAudioFile(forWriting: url, settings: fileSettings)
            audioFile = file

            // Set up stop word detection if enabled
            stopWordDetectionEnabled = withStopWordDetection && StopWordDefaults.isEnabled
            if stopWordDetectionEnabled {
                setupStopWordDetector()
            }

            // Create converter to convert from input format to our desired format
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw RecordingError.preparationFailed
            }

            // Install tap on input node
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                guard let self = self else { return }

                // Convert buffer to output format
                let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * self.outputFormat.sampleRate / inputFormat.sampleRate)
                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: self.outputFormat, frameCapacity: frameCount) else {
                    return
                }

                var error: NSError?
                let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }

                if status == .error {
                    logger.error("Audio conversion error: \(error?.localizedDescription ?? "unknown")")
                    return
                }

                // Write to file
                do {
                    try file.write(from: convertedBuffer)
                } catch {
                    logger.error("Failed to write audio: \(error.localizedDescription)")
                }

                // Feed to stop word detector if enabled
                if self.stopWordDetectionEnabled {
                    self.stopWordDetector?.appendAudioBuffer(convertedBuffer)
                }
            }

            // Start the engine
            try engine.start()

            audioEngine = engine
            isRecording = true
            recordingTime = 0
            recordingStartTime = Date()

            // Start timer on main thread
            startTimer()

            logger.info("Recording started successfully")

        } catch let error as RecordingError {
            throw error
        } catch {
            logger.error("Failed to start recording: \(error.localizedDescription)")
            throw RecordingError.recorderCreationFailed(error.localizedDescription)
        }
    }

    // Legacy method for compatibility
    func startRecording() throws {
        try startRecording(withStopWordDetection: StopWordDefaults.isEnabled)
    }

    func stopRecording() -> URL? {
        logger.info("Stopping recording...")

        stopTimer()

        // Stop stop word detector
        stopWordDetector?.stopListening()
        stopWordDetector = nil
        stopWordDetectionEnabled = false

        guard let engine = audioEngine else {
            logger.warning("No active engine to stop")
            isRecording = false
            return nil
        }

        // Get duration before stopping
        let duration = recordingTime

        // Stop the engine and remove tap
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        audioEngine = nil
        audioFile = nil
        isRecording = false

        guard duration > 0.1 else {
            logger.warning("Recording too short: \(duration)s")
            cleanupRecordingFile()
            return nil
        }

        logger.info("Recording stopped. Duration: \(String(format: "%.1f", duration))s")
        return recordingURL
    }

    func cancelRecording() {
        logger.info("Cancelling recording...")

        stopTimer()

        // Stop stop word detector
        stopWordDetector?.stopListening()
        stopWordDetector = nil
        stopWordDetectionEnabled = false

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        audioEngine = nil
        audioFile = nil
        isRecording = false
        recordingTime = 0

        cleanupRecordingFile()

        logger.info("Recording cancelled")
    }

    // MARK: - Private Methods

    private func setupStopWordDetector() {
        // Check current authorization status
        let status = StopWordDetector.authorizationStatus
        if status == .notDetermined {
            // Request authorization asynchronously
            Task {
                let newStatus = await StopWordDetector.requestAuthorization()
                if newStatus == .authorized {
                    await self.initializeStopWordDetector()
                } else {
                    logger.warning("Speech recognition authorization denied: \(newStatus.rawValue)")
                    self.stopWordDetectionEnabled = false
                }
            }
        } else if status == .authorized {
            initializeStopWordDetector()
        } else {
            logger.warning("Speech recognition not authorized: \(status.rawValue)")
            stopWordDetectionEnabled = false
        }
    }

    private func initializeStopWordDetector() {
        let detector = StopWordDetector()
        detector.onStopWordDetected = { [weak self] in
            Task { @MainActor in
                self?.handleStopWordDetected()
            }
        }
        detector.startListening()
        stopWordDetector = detector

        logger.info("Stop word detector set up and listening")
    }

    private func handleStopWordDetected() {
        guard isRecording else { return }
        logger.info("Stop word detected - triggering callback")
        onStopWordDetected?()
    }

    private func startTimer() {
        stopTimer() // Ensure no duplicate timers

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateRecordingTime()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateRecordingTime() {
        guard isRecording, let startTime = recordingStartTime else {
            return
        }
        recordingTime = Date().timeIntervalSince(startTime)
    }

    private func cleanupRecordingFile() {
        guard let url = recordingURL else { return }

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                logger.debug("Cleaned up recording file: \(url.lastPathComponent)")
            }
        } catch {
            logger.error("Failed to cleanup recording file: \(error.localizedDescription)")
        }

        recordingURL = nil
    }

    private func handleRecordingError(_ error: RecordingError) {
        lastError = error
        isRecording = false
        recordingTime = 0
        stopTimer()
        cleanupRecordingFile()
    }
}

// MARK: - Error Types

enum RecordingError: LocalizedError, Equatable {
    case invalidURL
    case permissionDenied
    case preparationFailed
    case recordingFailed
    case recordingInterrupted
    case recorderCreationFailed(String)
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Could not create recording file."
        case .permissionDenied:
            return "Microphone access denied. Please enable in System Settings."
        case .preparationFailed:
            return "Failed to prepare audio recorder."
        case .recordingFailed:
            return "Failed to start recording."
        case .recordingInterrupted:
            return "Recording was interrupted."
        case .recorderCreationFailed(let message):
            return "Failed to create recorder: \(message)"
        case .encodingFailed(let message):
            return "Audio encoding failed: \(message)"
        }
    }

    static func == (lhs: RecordingError, rhs: RecordingError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidURL, .invalidURL),
             (.permissionDenied, .permissionDenied),
             (.preparationFailed, .preparationFailed),
             (.recordingFailed, .recordingFailed),
             (.recordingInterrupted, .recordingInterrupted):
            return true
        case (.recorderCreationFailed(let l), .recorderCreationFailed(let r)):
            return l == r
        case (.encodingFailed(let l), .encodingFailed(let r)):
            return l == r
        default:
            return false
        }
    }
}
