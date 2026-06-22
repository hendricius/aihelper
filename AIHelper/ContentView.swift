import SwiftUI

struct ContentView: View {
    @EnvironmentObject var transcriptionStore: TranscriptionStore
    @EnvironmentObject var audioRecorder: AudioRecorder
    @EnvironmentObject var recordingManager: RecordingManager
    @EnvironmentObject var permissionManager: PermissionManager
    @EnvironmentObject var failedRequestStore: FailedRequestStore
    @State private var showingAllHistory = false
    @AppStorage(WakeWordDefaults.enabledKey) private var wakeWordEnabled = WakeWordDefaults.defaultEnabled

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Text("AIHelper")
                    .font(.headline)
                Spacer()

                Button(action: { SettingsWindowController.shared.showSettings() }) {
                    Image(systemName: "gear")
                        .accessibilityLabel("Settings")
                }
                .buttonStyle(.plain)
                .help("Settings")

                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Image(systemName: "xmark.circle")
                        .accessibilityLabel("Quit AIHelper")
                }
                .buttonStyle(.plain)
                .help("Quit AIHelper")
            }

            Divider()

            // Permission warnings
            if !permissionManager.hasAccessibilityPermission || !permissionManager.hasMicrophonePermission {
                VStack(spacing: 6) {
                    if !permissionManager.hasAccessibilityPermission {
                        HStack {
                            Image(systemName: "keyboard")
                                .foregroundColor(.orange)
                            Text("Shortcut needs Accessibility permission")
                                .font(.caption)
                            Spacer()
                            Button("Fix") {
                                permissionManager.openAccessibilitySettings()
                            }
                            .font(.caption)
                        }
                    }

                    if !permissionManager.hasMicrophonePermission {
                        HStack {
                            Image(systemName: "mic.slash")
                                .foregroundColor(.red)
                            Text("Microphone access needed")
                                .font(.caption)
                            Spacer()
                            Button("Fix") {
                                permissionManager.requestMicrophonePermission()
                            }
                            .font(.caption)
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Recheck All") {
                            permissionManager.checkAllPermissions()
                            // Re-register shortcuts if accessibility granted
                            if permissionManager.hasAccessibilityPermission {
                                (NSApp.delegate as? AppDelegate)?.registerShortcuts()
                            }
                        }
                        .font(.caption)
                        Button("Open Settings") {
                            permissionManager.openSystemSettings()
                        }
                        .font(.caption)
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            }

            // Recording section - more compact
            HStack(spacing: 16) {
                // Recording button
                Button(action: { recordingManager.toggleRecording() }) {
                    ZStack {
                        Circle()
                            .fill(recordingButtonColor)
                            .frame(width: 50, height: 50)

                        if recordingManager.isTranscribing {
                            ProgressView()
                                .scaleEffect(1.0)
                                .tint(.white)
                        } else {
                            Image(systemName: audioRecorder.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(recordingManager.isTranscribing)
                .accessibilityLabel(recordingAccessibilityLabel)
                .accessibilityHint(audioRecorder.isRecording ? "Double tap to stop recording" : "Double tap to start recording")

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusText)
                        .font(.subheadline)

                    HStack(spacing: 8) {
                        Text("⌃⌥⌘⇧R")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("Transcribe")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 8) {
                        Text("⌃⌥⌘⇧E")
                            .font(.caption2)
                            .foregroundColor(.orange)
                        Text("Email")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }

                    HStack(spacing: 8) {
                        Text("⌃⌥⌘⇧T")
                            .font(.caption2)
                            .foregroundColor(.green)
                        Text("Message")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }

                    if audioRecorder.isRecording {
                        Text(formatTime(audioRecorder.recordingTime))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(recordingManager.currentMode == .email ? .orange : .red)
                    }
                }

                Spacer()
            }

            // Wake word status bar
            WakeWordStatusBar(isEnabled: $wakeWordEnabled)

            // Error message
            if let error = recordingManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            // Failed requests section
            if !failedRequestStore.failedRequests.isEmpty {
                VStack(spacing: 8) {
                    ForEach(failedRequestStore.failedRequests) { request in
                        FailedRequestRow(
                            request: request,
                            isRetrying: recordingManager.isRetrying,
                            onRetry: { recordingManager.retryFailedRequest(request) },
                            onDismiss: { recordingManager.dismissFailedRequest(request) }
                        )
                    }
                }
            }

            Divider()

            // Recent transcriptions
            if transcriptionStore.transcriptions.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "mic.circle")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No transcriptions yet")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    VStack(spacing: 4) {
                        Text("Press ⌃⌥⌘⇧R to transcribe")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Press ⌃⌥⌘⇧E for email mode")
                            .font(.caption)
                            .foregroundColor(.orange.opacity(0.8))
                    }
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(recentTranscriptions) { transcription in
                            CompactTranscriptionRow(
                                transcription: transcription,
                                onCopy: { recordingManager.copyToClipboard(transcription.text) },
                                onCopyDebug: { recordingManager.copyToClipboard(transcription.debugSummary()) }
                            )
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: 380, height: calculatedHeight)
        .overlay {
            if recordingManager.showCopiedFeedback {
                Text("Copied!")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: recordingManager.showCopiedFeedback)
        .animation(.easeInOut(duration: 0.2), value: showingAllHistory)
    }

    private var recentTranscriptions: [Transcription] {
        if showingAllHistory {
            return transcriptionStore.transcriptions
        } else {
            return Array(transcriptionStore.transcriptions.prefix(2))
        }
    }

    private var calculatedHeight: CGFloat {
        var height: CGFloat = showingAllHistory ? 500 : 340  // Base height increased for wake word bar

        // Add extra height for permission warnings
        if !permissionManager.hasAccessibilityPermission {
            height += 30
        }
        if !permissionManager.hasMicrophonePermission {
            height += 30
        }
        if !permissionManager.hasAccessibilityPermission || !permissionManager.hasMicrophonePermission {
            height += 30  // Extra for the "Recheck All" / "Open Settings" buttons row
        }

        // Add height for failed requests
        if !failedRequestStore.failedRequests.isEmpty {
            height += CGFloat(failedRequestStore.failedRequests.count) * 80
        }

        return height
    }

    private var statusText: String {
        if recordingManager.isTranscribing {
            return recordingManager.currentMode == .email ? "Formatting email..." : "Transcribing..."
        } else if audioRecorder.isRecording {
            return recordingManager.currentMode == .email ? "Recording email..." : "Recording..."
        } else {
            return "Ready to record"
        }
    }

    private var recordingButtonColor: Color {
        if audioRecorder.isRecording {
            return recordingManager.currentMode == .email ? Color.orange : Color.red
        }
        return Color.accentColor
    }

    private var recordingAccessibilityLabel: String {
        if recordingManager.isTranscribing {
            return "Transcribing in progress"
        } else if audioRecorder.isRecording {
            return "Stop recording"
        } else {
            return "Start recording"
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

struct CompactTranscriptionRow: View {
    let transcription: Transcription
    let onCopy: () -> Void
    let onCopyDebug: () -> Void
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    // Mode and metadata badges
                    HStack(spacing: 4) {
                        ModeBadge(mode: transcription.mode)

                        if transcription.formattingApplied {
                            Text("Formatted")
                                .font(.system(size: 9))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.2))
                                .foregroundColor(.green)
                                .cornerRadius(3)
                        }

                        if let prompt = transcription.promptUsed {
                            Text(prompt)
                                .font(.system(size: 9))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.purple.opacity(0.2))
                                .foregroundColor(.purple)
                                .cornerRadius(3)
                                .lineLimit(1)
                        }
                    }

                    Text(transcription.text)
                        .font(.callout)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Text(transcription.date, style: .relative)
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        if hasDebugInfo {
                            Button(action: { showingDetails.toggle() }) {
                                HStack(spacing: 2) {
                                    Text(showingDetails ? "Hide details" : "Show details")
                                    Image(systemName: showingDetails ? "chevron.up" : "chevron.down")
                                }
                                .font(.caption2)
                                .foregroundColor(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer(minLength: 8)

                VStack(spacing: 4) {
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14))
                            .accessibilityLabel("Copy to clipboard")
                    }
                    .buttonStyle(.plain)
                    .help("Copy to clipboard")

                    if hasDebugInfo {
                        Button(action: onCopyDebug) {
                            Image(systemName: "ladybug")
                                .font(.system(size: 12))
                                .accessibilityLabel("Copy debug info")
                        }
                        .buttonStyle(.plain)
                        .help("Copy debug info")
                    }
                }
            }

            // Expandable debug details section
            if showingDetails {
                VStack(alignment: .leading, spacing: 8) {
                    // Raw transcription (if available)
                    if let rawText = transcription.rawTranscription {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Raw Transcription:")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)

                            Text(rawText)
                                .font(.caption)
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.05))
                        .cornerRadius(4)
                    }

                    // Original email context (if available)
                    if let context = transcription.originalContext {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Original Email:")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)

                            Text(context)
                                .font(.caption)
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.05))
                        .cornerRadius(4)
                    }

                    // Formatted output
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Formatted Output:")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)

                        Text(transcription.text)
                            .font(.caption)
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.05))
                    .cornerRadius(4)
                }
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(6)
    }

    private var hasDebugInfo: Bool {
        transcription.originalContext != nil || transcription.rawTranscription != nil || transcription.formattingApplied
    }
}

struct ModeBadge: View {
    let mode: TranscriptionMode

    var body: some View {
        Text(mode.displayName)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(backgroundColor)
            .foregroundColor(foregroundColor)
            .cornerRadius(3)
    }

    private var backgroundColor: Color {
        switch mode {
        case .transcription: return Color.gray.opacity(0.2)
        case .email: return Color.orange.opacity(0.2)
        case .formatting: return Color.blue.opacity(0.2)
        case .casualMessage: return Color.green.opacity(0.2)
        }
    }

    private var foregroundColor: Color {
        switch mode {
        case .transcription: return .secondary
        case .email: return .orange
        case .formatting: return .blue
        case .casualMessage: return .green
        }
    }
}

struct FailedRequestRow: View {
    let request: FailedRequest
    let isRetrying: Bool
    let onRetry: () -> Void
    let onDismiss: () -> Void

    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(requestTypeLabel)
                            .font(.caption)
                            .fontWeight(.medium)

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.secondary)
                    }

                    Text(request.date, style: .relative)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isRetrying {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Button(action: onRetry) {
                        Text("Retry")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)

                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }

            if isExpanded {
                HStack(alignment: .top, spacing: 6) {
                    Text(request.errorMessage)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)

                    Spacer()

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(request.errorMessage, forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy error message")
                }
                .padding(.top, 6)
                .padding(.leading, 28)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(6)
    }

    private var requestTypeLabel: String {
        switch request.requestType {
        case .transcription:
            return "Saved recording (connection lost)"
        case .formatting:
            return "Saved text (connection lost)"
        }
    }
}

// MARK: - Wake Word Status Bar

struct WakeWordStatusBar: View {
    @Binding var isEnabled: Bool
    @ObservedObject private var wakeWordDetector = AppState.shared.wakeWordDetector
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 10) {
            // Listening indicator with animation
            ZStack {
                if isEnabled && wakeWordDetector.isListening {
                    Circle()
                        .fill(Color.green.opacity(0.3))
                        .frame(width: 24, height: 24)
                        .scaleEffect(isPulsing ? 1.3 : 1.0)
                        .opacity(isPulsing ? 0.0 : 0.5)
                        .animation(
                            .easeInOut(duration: 1.5).repeatForever(autoreverses: false),
                            value: isPulsing
                        )
                }

                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)

                if isEnabled && wakeWordDetector.isListening {
                    Image(systemName: "waveform")
                        .font(.system(size: 6))
                        .foregroundColor(.white)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(statusText)
                        .font(.caption)
                        .fontWeight(.medium)

                    if isEnabled {
                        Text("\"\(WakeWordDefaults.wakeWord)\"")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }

                if isEnabled && wakeWordDetector.isListening {
                    Text("Say the wake word to start recording")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .scaleEffect(0.8)
                .onChange(of: isEnabled) { _, newValue in
                    if newValue {
                        AppState.shared.wakeWordDetector.startListening()
                    } else {
                        AppState.shared.wakeWordDetector.stopListening()
                    }
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isEnabled ? Color.green.opacity(0.1) : Color.gray.opacity(0.1))
        .cornerRadius(8)
        .onAppear {
            if isEnabled && wakeWordDetector.isListening {
                isPulsing = true
            }
        }
        .onChange(of: wakeWordDetector.isListening) { _, isListening in
            isPulsing = isListening
        }
    }

    private var statusColor: Color {
        if isEnabled && wakeWordDetector.isListening {
            return .green
        } else if isEnabled {
            return .orange
        } else {
            return .gray
        }
    }

    private var statusText: String {
        if !isEnabled {
            return "Wake word off"
        } else if wakeWordDetector.isListening {
            return "Listening for"
        } else {
            return "Wake word paused"
        }
    }
}

#Preview {
    let transcriptionStore = TranscriptionStore()
    let failedRequestStore = FailedRequestStore()
    ContentView()
        .environmentObject(transcriptionStore)
        .environmentObject(AudioRecorder())
        .environmentObject(RecordingManager(
            audioRecorder: AudioRecorder(),
            transcriptionStore: transcriptionStore,
            failedRequestStore: failedRequestStore
        ))
        .environmentObject(PermissionManager.shared)
        .environmentObject(failedRequestStore)
}
