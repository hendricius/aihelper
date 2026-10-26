import AVFoundation
import AppKit
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "MeetingRecorder")

/// Records a meeting as two tracks in its folder: the microphone (you) and the Mac's audio
/// output (everyone else on the call). Nothing joins the call; whatever the Mac plays is
/// recorded, so it works the same in Zoom, Meet, Teams, Slack, FaceTime or a browser tab.
///
/// When recording stops, `MeetingTranscriber` takes over.
@MainActor
final class MeetingRecorder: ObservableObject {
    static let shared = MeetingRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// False when the Mac's audio could not be tapped (macOS before 14.2, or the tap failed):
    /// only the microphone is recorded then.
    @Published private(set) var capturesSystemAudio = false
    @Published private(set) var lastError: String?

    private var meetingID: UUID?
    private var engine: AVAudioEngine?
    private var microphoneWriter: MeetingTrackWriter?
    private var systemWriter: MeetingTrackWriter?
    /// A `SystemAudioCapture`; typed loosely because that class needs macOS 14.2.
    private var systemCapture: AnyObject?
    private var configurationObserver: NSObjectProtocol?
    private var timer: Timer?
    private var startUptime: TimeInterval = 0
    private var lastToggle: TimeInterval = 0

    /// The meeting being recorded right now.
    var currentMeetingID: UUID? { meetingID }

    func toggle() {
        // A bounced key press must not start a meeting and stop it again a moment later.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastToggle > 0.5 else { return }
        lastToggle = now
        isRecording ? stop() : start()
    }

    func start() {
        guard !isRecording else { return }
        Task { await startRecording() }
    }

    private func startRecording() async {
        lastError = nil
        guard await microphoneAccessGranted() else {
            report("Microphone access is needed to record meetings. Grant it in System Settings › Privacy & Security › Microphone.")
            return
        }
        guard !isRecording else { return }

        let store = MeetingStore.shared
        var created: Meeting?
        do {
            let meeting = try store.createMeeting(startedAt: Date())
            created = meeting
            let uptime = ProcessInfo.processInfo.systemUptime
            startUptime = uptime
            // Monotonic, so a clock adjustment mid-meeting cannot shift one track against the other.
            let clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime - uptime }
            microphoneWriter = try MeetingTrackWriter(url: store.audioURL(for: .microphone, of: meeting), clock: clock)
            systemWriter = try MeetingTrackWriter(url: store.audioURL(for: .system, of: meeting), clock: clock)

            try startMicrophone()
            startSystemAudio()

            var started = meeting
            started.capturedSystemAudio = capturesSystemAudio
            store.update(started)

            meetingID = meeting.id
            elapsed = 0
            isRecording = true
            startTimer()
            StatusOverlay.shared.showBrief(message: capturesSystemAudio ? "Recording meeting" : "Recording meeting (microphone only)")
            logger.info("Meeting recording started: \(meeting.folderName, privacy: .public), system audio: \(self.capturesSystemAudio, privacy: .public)")
        } catch {
            tearDown()
            if let created { store.discard(created) }
            report("Could not start the meeting recording: \(error.localizedDescription)")
        }
    }

    /// Stops recording and hands the meeting to the transcriber.
    func stop() {
        guard let meetingID = finishRecording() else { return }
        StatusOverlay.shared.showBrief(message: "Meeting saved — transcribing")
        MeetingTranscriber.shared.transcribe(meetingID: meetingID)
    }

    /// Closes the tracks cleanly when the app quits mid-meeting. The transcript is made on the
    /// next launch (see `MeetingTranscriber.resumeUnfinished()`).
    func stopForTermination() {
        _ = finishRecording()
    }

    private func finishRecording() -> UUID? {
        guard isRecording, let meetingID else { return nil }
        let microphoneLength = microphoneWriter?.finish() ?? 0
        let systemLength = systemWriter?.finish() ?? 0
        let wallClock = ProcessInfo.processInfo.systemUptime - startUptime
        tearDown()

        let store = MeetingStore.shared
        if var meeting = store.meeting(id: meetingID) {
            meeting.duration = max(microphoneLength, systemLength, wallClock)
            meeting.status = .transcribing
            store.update(meeting)
        }
        logger.info("Meeting recording stopped after \(Int(wallClock), privacy: .public)s")
        return meetingID
    }

    private func tearDown() {
        timer?.invalidate()
        timer = nil
        stopMicrophone()
        if #available(macOS 14.2, *) {
            (systemCapture as? SystemAudioCapture)?.stop()
        }
        systemCapture = nil
        microphoneWriter?.finish()
        systemWriter?.finish()
        microphoneWriter = nil
        systemWriter = nil
        meetingID = nil
        isRecording = false
    }

    // MARK: - Microphone

    private func microphoneAccessGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func startMicrophone() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "MeetingRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone available."])
        }

        let writer = microphoneWriter
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            writer?.append(buffer)
        }
        try engine.start()
        self.engine = engine

        // Plugging in a headset or joining a call on AirPods switches the input device, which
        // stops the engine. Start it again on the new device; the writer bridges the gap.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartMicrophone() }
        }
    }

    private func restartMicrophone() {
        guard isRecording else { return }
        logger.info("Audio configuration changed — restarting the microphone")
        stopMicrophone()
        do {
            try startMicrophone()
        } catch {
            report("The microphone stopped: \(error.localizedDescription)")
        }
    }

    private func stopMicrophone() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    // MARK: - System audio

    private func startSystemAudio() {
        capturesSystemAudio = false
        guard #available(macOS 14.2, *) else {
            logger.info("System audio capture needs macOS 14.2 — recording the microphone only")
            return
        }
        let capture = SystemAudioCapture()
        let writer = systemWriter
        do {
            try capture.start { buffer in writer?.append(buffer) }
            systemCapture = capture
            capturesSystemAudio = true
        } catch {
            logger.error("System audio tap failed: \(error.localizedDescription, privacy: .public)")
            lastError = "The Mac's audio is not being recorded: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.elapsed = ProcessInfo.processInfo.systemUptime - self.startUptime
            }
        }
    }

    private func report(_ message: String) {
        logger.error("\(message, privacy: .public)")
        lastError = message
        StatusOverlay.shared.showBrief(message: message)
    }
}
