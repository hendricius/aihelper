import SwiftUI
import Combine
import os.log

private let logger = Logger(subsystem: "com.aihelper.app", category: "AppState")

// Shared app state accessible from AppDelegate
@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    let transcriptionStore: TranscriptionStore
    let audioRecorder: AudioRecorder
    let permissionManager: PermissionManager
    let failedRequestStore: FailedRequestStore
    let wakeWordDetector: WakeWordDetector

    lazy var recordingManager = RecordingManager(
        audioRecorder: audioRecorder,
        transcriptionStore: transcriptionStore,
        failedRequestStore: failedRequestStore
    )

    private var cancellables = Set<AnyCancellable>()

    init() {
        logger.info("Initializing AppState...")

        // Ensure audio storage directory exists
        AudioFileManager.ensureDirectoryExists()

        // Initialize components with crash protection
        self.transcriptionStore = TranscriptionStore()
        self.audioRecorder = AudioRecorder()
        self.permissionManager = PermissionManager.shared
        self.failedRequestStore = FailedRequestStore()
        self.wakeWordDetector = WakeWordDetector()

        // Start clipboard history monitoring
        _ = ClipboardHistoryStore.shared

        // Forward changes from child objects to trigger view updates
        audioRecorder.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        permissionManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        failedRequestStore.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        wakeWordDetector.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Use Task to access lazy recordingManager
        Task { @MainActor in
            self.recordingManager.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &self.cancellables)

            // Set up wake word detector integration
            self.setupWakeWordDetector()
        }

        logger.info("AppState initialized successfully")
    }

    /// Track if recording was triggered by wake word (to know when to resume)
    private var wakeWordTriggeredRecording = false

    /// Track previous busy state to detect transitions
    private var wasBusy = false

    private func setupWakeWordDetector() {
        // When wake word is detected, start recording
        wakeWordDetector.onWakeWordDetected = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }

                // Don't start if already recording or processing
                let manager = self.recordingManager
                if manager.isTranscribing || manager.isFormatting || self.audioRecorder.isRecording {
                    logger.info("Wake word detected but already recording/processing, ignoring")
                    return
                }

                logger.info("Wake word triggered recording")
                self.wakeWordTriggeredRecording = true

                // Start recording - use formatting mode if configured
                if WakeWordDefaults.useFormattingMode {
                    manager.toggleFormattingRecording()
                } else {
                    manager.toggleRecording()
                }
            }
        }

        // Only resume wake word detection after a wake-word-triggered recording completes
        recordingManager.$isTranscribing
            .combineLatest(recordingManager.$isFormatting, audioRecorder.$isRecording)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] isTranscribing, isFormatting, isRecording in
                guard let self = self else { return }

                let isBusy = isTranscribing || isFormatting || isRecording

                // Only act on state transitions
                if isBusy && !self.wasBusy {
                    // Just became busy - pause wake word detection
                    self.wakeWordDetector.pauseListening()
                } else if !isBusy && self.wasBusy {
                    // Just became idle - resume if this was a wake word session
                    if self.wakeWordTriggeredRecording {
                        self.wakeWordTriggeredRecording = false
                        self.wakeWordDetector.resumeListening()
                    }
                }

                self.wasBusy = isBusy
            }
            .store(in: &cancellables)

        // Start wake word detection if enabled (with delay to let app settle)
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await wakeWordDetector.startListening()
        }
    }
}

@main
struct AIHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var appState = AppState.shared

    private var menuBarIcon: String {
        if appState.recordingManager.isTranscribing {
            return "ellipsis.circle"
        } else if appState.audioRecorder.isRecording {
            return "record.circle.fill"
        } else {
            return "mic"
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(appState.transcriptionStore)
                .environmentObject(appState.audioRecorder)
                .environmentObject(appState.recordingManager)
                .environmentObject(appState.permissionManager)
                .environmentObject(appState.failedRequestStore)
        } label: {
            Image(systemName: menuBarIcon)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState.transcriptionStore)
        }
    }
}
