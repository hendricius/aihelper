import SwiftUI

struct StopWordExample {
    let word: String
    let description: String
}

private let exampleStopWords: [StopWordExample] = [
    StopWordExample(word: "over", description: "Radio-style — clear and unambiguous"),
    StopWordExample(word: "Ende", description: "German signal for the end of a message"),
    StopWordExample(word: "fertig", description: "Natural German closing word"),
    StopWordExample(word: "done", description: "English closing word"),
    StopWordExample(word: "stop", description: "Universal stop word"),
    StopWordExample(word: "aus", description: "Short and concise"),
    StopWordExample(word: "Punkt", description: "Like dictation — signals the end"),
    StopWordExample(word: "okay", description: "Natural way to end a conversation"),
]

struct SettingsView: View {
    @AppStorage("aicoordinator_api_key") private var apiKey = ""
    @AppStorage("openai_api_key") private var openAIKey = ""
    @AppStorage(APIProvider.activeProviderDefaultsKey) private var activeProviderRaw = APIProvider.openAI.rawValue
    @AppStorage("email_format_prompt") private var emailPrompt = EmailDefaults.prompt
    @EnvironmentObject var transcriptionStore: TranscriptionStore
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @State private var showingAPIKey = false
    @State private var showingOpenAIKey = false
    @State private var selectedSection: SettingsSection? = nil
    @State private var vocabularyText: String = VocabularyDefaults.getVocabulary()
    @AppStorage(StopWordDefaults.enabledKey) private var stopWordEnabled = StopWordDefaults.defaultEnabled
    @AppStorage(StopWordDefaults.wordKey) private var stopWord = StopWordDefaults.defaultStopWord
    @AppStorage(StopWordDefaults.autoPasteKey) private var stopWordAutoPaste = StopWordDefaults.defaultAutoPaste
    @AppStorage(WakeWordDefaults.enabledKey) private var wakeWordEnabled = WakeWordDefaults.defaultEnabled
    @AppStorage(WakeWordDefaults.wordKey) private var wakeWord = WakeWordDefaults.defaultWakeWord
    @AppStorage(WakeWordDefaults.useFormattingModeKey) private var wakeWordUseFormatting = WakeWordDefaults.defaultUseFormattingMode
    @AppStorage(HyperKeyManager.enabledKey) private var hyperKeyEnabled = true
    @AppStorage(WelcomeWindowController.completedKey) private var welcomeCompleted = false
    @StateObject private var devMachinesViewModel = DevelopmentMachinesViewModel()
    @ObservedObject private var caffeine = CaffeineManager.shared

    private var activeProvider: APIProvider {
        APIProvider(rawValue: activeProviderRaw) ?? .openAI
    }

    /// Whether the currently selected provider has an API key configured.
    private var activeProviderConfigured: Bool {
        switch activeProvider {
        case .aiCoordinator: return !apiKey.isEmpty
        case .openAI: return !openAIKey.isEmpty
        }
    }

    @StateObject private var audioPlayer = AudioPlayerManager.shared
    @State private var historySearchText = ""
    @State private var historyModeFilter: TranscriptionMode? = nil
    @State private var expandedTranscriptionId: UUID? = nil

    enum SettingsSection: String, Identifiable {
        case general
        case history
        case vocabulary
        case wakeWord
        case stopWord
        case hyperKey
        case caffeine
        case developmentMachines
        case api
        case email
        case about
        case developer

        var id: String { rawValue }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Section {
                    settingsRow(
                        icon: "gear",
                        title: "General",
                        subtitle: "\(transcriptionStore.transcriptions.count) transcriptions",
                        section: .general
                    )

                    settingsRow(
                        icon: "clock.arrow.circlepath",
                        title: "History",
                        subtitle: "\(transcriptionStore.transcriptions.count) entries",
                        section: .history
                    )

                    settingsRow(
                        icon: "text.book.closed",
                        title: "Vocabulary",
                        subtitle: "Technical terms",
                        section: .vocabulary
                    )

                    settingsRow(
                        icon: "waveform.badge.mic",
                        title: "Wake Word",
                        subtitle: wakeWordEnabled ? "Enabled" : "Disabled",
                        section: .wakeWord
                    )

                    settingsRow(
                        icon: "stop.circle",
                        title: "Stop Word",
                        subtitle: stopWordEnabled ? "Enabled" : "Disabled",
                        section: .stopWord
                    )

                    settingsRow(
                        icon: "capslock",
                        title: "Hyper Key",
                        subtitle: hyperKeyEnabled ? "Caps Lock → ⌃⌥⌘⇧" : "Off",
                        section: .hyperKey
                    )

                    settingsRow(
                        icon: "cup.and.saucer",
                        title: "Keep Awake",
                        subtitle: caffeine.isActive ? "On — \(caffeine.remainingText) left" : "Off · \(caffeine.durationHours)h",
                        section: .caffeine
                    )

                    settingsRow(
                        icon: "desktopcomputer",
                        title: "Development Machines",
                        subtitle: devMachinesSubtitle,
                        section: .developmentMachines
                    )

                }

                Section {
                    settingsRow(
                        icon: "key",
                        title: "API",
                        subtitle: "\(activeProvider.displayName) — \(activeProviderConfigured ? "Configured" : "Not configured")",
                        section: .api
                    )

                    settingsRow(
                        icon: "envelope",
                        title: "Email",
                        subtitle: "Formatting Prompt",
                        section: .email
                    )
                }

                Section {
                    settingsRow(
                        icon: "info.circle",
                        title: "About",
                        subtitle: appVersion,
                        section: .about
                    )

                    settingsRow(
                        icon: "hammer",
                        title: "Developer",
                        subtitle: welcomeCompleted ? "Tools" : "Onboarding on next launch",
                        section: .developer
                    )
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .navigationTitle("Settings")
        } detail: {
            if let section = selectedSection {
                detailView(for: section)
            } else {
                // Default overview when nothing is selected
                settingsOverview
            }
        }
        .frame(width: 700, height: 500)
    }

    @ViewBuilder
    private func settingsRow(icon: String, title: String, subtitle: String, section: SettingsSection) -> some View {
        NavigationLink(value: section) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(.accentColor)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func detailView(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            generalSettings
        case .history:
            transcriptionHistoryView
        case .vocabulary:
            vocabularySettings
        case .wakeWord:
            wakeWordSettings
        case .stopWord:
            stopWordSettings
        case .hyperKey:
            hyperKeySettings
        case .caffeine:
            caffeineSettings
        case .developmentMachines:
            developmentMachinesSettings
        case .api:
            apiSettings
        case .email:
            emailSettings
        case .about:
            aboutView
        case .developer:
            developerSettings
        }
    }

    // MARK: - Developer

    private var developerSettings: some View {
        Form {
            Section {
                Button {
                    WelcomeWindowController.shared.replayFromStart()
                } label: {
                    Label("Show onboarding now", systemImage: "play.circle")
                }

                Toggle("Show onboarding on next launch", isOn: Binding(
                    get: { !welcomeCompleted },
                    set: { showOnLaunch in
                        welcomeCompleted = !showOnLaunch
                        if showOnLaunch { UserDefaults.standard.set(0, forKey: WelcomeWindowController.stepKey) }
                    }
                ))
            } header: {
                Label("Onboarding", systemImage: "sparkles")
            } footer: {
                Text("Replay the first-launch welcome. The toggle simply marks onboarding as not-yet-seen, so it appears the next time AIHelper starts — quit and relaunch to test the real launch flow.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var settingsOverview: some View {
        VStack(spacing: 24) {
            Image(systemName: "gear")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("Settings")
                .font(.title)

            Text("Select a category on the left")
                .font(.body)
                .foregroundColor(.secondary)

            // Quick status overview
            VStack(alignment: .leading, spacing: 16) {
                Divider()

                HStack {
                    Label("Transcriptions", systemImage: "doc.text")
                    Spacer()
                    Text("\(transcriptionStore.transcriptions.count)")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Label("Provider", systemImage: "switch.2")
                    Spacer()
                    Text(activeProvider.displayName)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Label("API Key", systemImage: "key")
                    Spacer()
                    Text(activeProviderConfigured ? "Configured" : "Not configured")
                        .foregroundColor(activeProviderConfigured ? .green : .orange)
                }

                HStack {
                    Label("Network", systemImage: "wifi")
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(networkMonitor.isConnected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(networkMonitor.isConnected ? "Online" : "Offline")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transcription History")
                .font(.headline)

            HStack {
                Text("Stored Transcriptions:")
                Spacer()
                Text("\(transcriptionStore.transcriptions.count)")
                    .foregroundColor(.secondary)
            }

            Button("Clear All Transcriptions") {
                transcriptionStore.clearAll()
            }
            .disabled(transcriptionStore.transcriptions.isEmpty)

            Spacer()
        }
        .padding()
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var apiSettings: some View {
        Form {
            Section {
                Picker("Active Provider", selection: $activeProviderRaw) {
                    ForEach(APIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text("Choose which API is used for transcription and formatting, then enter the matching key below.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Label("Provider", systemImage: "switch.2")
            }

            Section {
                HStack {
                    if showingOpenAIKey {
                        TextField("OpenAI API Key", text: $openAIKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("OpenAI API Key", text: $openAIKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button(action: { showingOpenAIKey.toggle() }) {
                        Image(systemName: showingOpenAIKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                }

                Text("Get your API key from [platform.openai.com](https://platform.openai.com/api-keys)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Label("OpenAI API Key", systemImage: "key")
            }

            Section {
                HStack {
                    if showingAPIKey {
                        TextField("AI Coordinator API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("AI Coordinator API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button(action: { showingAPIKey.toggle() }) {
                        Image(systemName: showingAPIKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Label("AI Coordinator API Key", systemImage: "key")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var emailSettings: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Email Formatting Prompt")
                        .font(.headline)

                    TextEditor(text: $emailPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                        .border(Color.gray.opacity(0.3), width: 1)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Use these placeholders in your prompt:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("{{selected_text}} - The email you're replying to")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.orange)
                        Text("{{transcription}} - Your dictated response")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.orange)
                    }

                    HStack {
                        Text("Shortcut: ⌃⌥⌘⇧E")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Spacer()

                        Button("Reset to Default") {
                            emailPrompt = EmailDefaults.prompt
                        }
                        .font(.caption)
                    }

                    Text("Tip: Select the email text before pressing the shortcut.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var vocabularySettings: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("These terms help transcription recognize and spell technical vocabulary correctly.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextEditor(text: $vocabularyText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 150)
                        .border(Color.gray.opacity(0.3), width: 1)
                        .onChange(of: vocabularyText) { _, newValue in
                            VocabularyDefaults.saveVocabulary(newValue)
                        }

                    Text("Separate terms with commas. Example: Sauerteig, Autolyse, Bulk Fermentation")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Label("Fachvokabular", systemImage: "text.book.closed")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Included categories:")
                        .font(.caption)
                        .fontWeight(.medium)

                    VStack(alignment: .leading, spacing: 4) {
                        vocabularyCategoryRow(icon: "person.text.rectangle", text: "Proper names: theBread.code(), Loafy, Gluten Tag")
                        vocabularyCategoryRow(icon: "arrow.triangle.2.circlepath", text: "Processes: Bulk Fermentation, Autolyse, Proofing")
                        vocabularyCategoryRow(icon: "leaf", text: "Ingredients: Levain, Poolish, Biga, Tangzhong")
                        vocabularyCategoryRow(icon: "hammer", text: "Equipment: Banneton, Dutch Oven, Lame")
                        vocabularyCategoryRow(icon: "waveform.path.ecg", text: "Properties: Crumb, Oven Spring, Hydration")
                    }
                }
            } header: {
                Label("Default Vocabulary", systemImage: "info.circle")
            }

            Section {
                HStack {
                    Button("Reset") {
                        VocabularyDefaults.resetToDefault()
                        vocabularyText = VocabularyDefaults.getVocabulary()
                    }
                    .font(.caption)

                    Spacer()

                    Text("\(vocabularyText.components(separatedBy: ",").count) terms")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func vocabularyCategoryRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var wakeWordSettings: some View {
        Form {
            Section {
                Toggle("Enable wake word detection", isOn: $wakeWordEnabled)
                    .onChange(of: wakeWordEnabled) { _, newValue in
                        if newValue {
                            AppState.shared.wakeWordDetector.startListening()
                        } else {
                            AppState.shared.wakeWordDetector.stopListening()
                        }
                    }

                if wakeWordEnabled {
                    HStack {
                        Text("Wake word:")
                        TextField("dictate", text: $wakeWord)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 150)
                    }

                    Toggle("Use formatting mode", isOn: $wakeWordUseFormatting)

                    Text(wakeWordUseFormatting
                        ? "Transcription is formatted with the active prompt"
                        : "Plain transcription without formatting")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Label("Settings", systemImage: "waveform.badge.mic")
            } footer: {
                Text("When enabled, you can start recording by saying the wake word — completely hands-free.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How it works:")
                        .font(.caption)
                        .fontWeight(.medium)

                    VStack(alignment: .leading, spacing: 4) {
                        featureRow(icon: "waveform.badge.mic", text: "Say \"\(wakeWord)\" to start recording")
                        featureRow(icon: "mic.fill", text: "Recording starts automatically")
                        featureRow(icon: "waveform", text: "Speak your text")
                        featureRow(icon: "stop.fill", text: "Say \"\(stopWord)\" to finish (when the stop word is enabled)")
                        featureRow(icon: "text.cursor", text: "Text is transcribed and copied")
                    }
                }
            } header: {
                Label("How it works", systemImage: "info.circle")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Example wake words:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    FlowLayout(spacing: 8) {
                        ForEach(["dictate", "diktieren", "aufnehmen", "schreiben", "notieren"], id: \.self) { word in
                            Button {
                                wakeWord = word
                            } label: {
                                Text(word)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(wakeWord.lowercased() == word.lowercased() ? Color.accentColor : Color.secondary.opacity(0.2))
                                    .foregroundColor(wakeWord.lowercased() == word.lowercased() ? .white : .primary)
                                    .cornerRadius(12)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } header: {
                Label("Examples", systemImage: "list.bullet")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Notes:")
                        .font(.caption)
                        .fontWeight(.medium)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                                .frame(width: 16)
                            Text("The microphone stays active continuously to detect the wake word")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "lock.shield")
                                .foregroundColor(.green)
                                .frame(width: 16)
                            Text("Speech recognition runs locally on your device")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "battery.75")
                                .foregroundColor(.blue)
                                .frame(width: 16)
                            Text("May increase battery usage")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Label("Important", systemImage: "exclamationmark.circle")
            }

            Section {
                HStack {
                    Button("Reset to Defaults") {
                        WakeWordDefaults.resetToDefaults()
                        wakeWordEnabled = WakeWordDefaults.defaultEnabled
                        wakeWord = WakeWordDefaults.defaultWakeWord
                        wakeWordUseFormatting = WakeWordDefaults.defaultUseFormattingMode
                        AppState.shared.wakeWordDetector.stopListening()
                    }
                    .font(.caption)

                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var stopWordSettings: some View {
        Form {
            Section {
                Toggle("Enable stop word detection", isOn: $stopWordEnabled)

                if stopWordEnabled {
                    HStack {
                        Text("Stop word:")
                        TextField("over", text: $stopWord)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 150)
                    }

                    Toggle("Automatically paste and press Enter", isOn: $stopWordAutoPaste)
                }
            } header: {
                Label("Settings", systemImage: "stop.circle")
            } footer: {
                Text("When enabled, recording stops automatically as soon as the stop word is detected.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How it works:")
                        .font(.caption)
                        .fontWeight(.medium)

                    VStack(alignment: .leading, spacing: 4) {
                        featureRow(icon: "mic", text: "Start recording (any mode)")
                        featureRow(icon: "waveform", text: "Speak and finish with the stop word")
                        featureRow(icon: "stop.fill", text: "Recording stops automatically")
                        featureRow(icon: "text.cursor", text: "Text is transcribed (without the stop word)")
                        if stopWordAutoPaste {
                            featureRow(icon: "doc.on.clipboard", text: "Text is pasted + Enter")
                        } else {
                            featureRow(icon: "doc.on.clipboard", text: "Text is copied to the clipboard")
                        }
                    }
                }
            } header: {
                Label("How it works", systemImage: "info.circle")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Klicke auf ein Wort, um es zu verwenden:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    FlowLayout(spacing: 8) {
                        ForEach(exampleStopWords, id: \.word) { example in
                            Button {
                                stopWord = example.word
                            } label: {
                                Text(example.word)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(stopWord.lowercased() == example.word.lowercased() ? Color.accentColor : Color.secondary.opacity(0.2))
                                    .foregroundColor(stopWord.lowercased() == example.word.lowercased() ? .white : .primary)
                                    .cornerRadius(12)
                            }
                            .buttonStyle(.plain)
                            .help(example.description)
                        }
                    }
                }
            } header: {
                Label("Example Stop Words", systemImage: "list.bullet")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Examples with stop word \"\(stopWord)\":")
                        .font(.caption)
                        .fontWeight(.medium)

                    Group {
                        Text("\"Hallo Welt \(stopWord)\" → \"Hallo Welt\"")
                        Text("\"Hallo Welt \(stopWord).\" → \"Hallo Welt\"")
                        Text("\"Hallo \(stopWord) Welt\" → \"Hallo \(stopWord) Welt\"")
                    }
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)

                    Text("The stop word is only removed at the end.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
            } header: {
                Label("Stop Word Removal", systemImage: "text.badge.minus")
            }

            Section {
                HStack {
                    Button("Reset to Defaults") {
                        StopWordDefaults.resetToDefaults()
                        stopWordEnabled = StopWordDefaults.defaultEnabled
                        stopWord = StopWordDefaults.defaultStopWord
                        stopWordAutoPaste = StopWordDefaults.defaultAutoPaste
                    }
                    .font(.caption)

                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var hyperKeySettings: some View {
        Form {
            Section {
                Toggle("Use Caps Lock as Hyper Key (⌃⌥⌘⇧)", isOn: $hyperKeyEnabled)
                    .onChange(of: hyperKeyEnabled) { _, on in
                        if on { HyperKeyManager.shared.enableRequestingPermissions() }
                        else { HyperKeyManager.shared.disable() }
                    }

                Text("Remaps Caps Lock to the \"hyper\" key. While you hold Caps Lock, your keypresses get Control-Option-Command-Shift added — so **Caps Lock + R** triggers recording, **Caps Lock + C** opens clipboard history, and so on. This replaces the separate Hyperkey app.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Label("Hyper Key", systemImage: "capslock")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    featureRow(icon: "1.circle", text: "Caps Lock no longer toggles caps — hold Shift to type capitals")
                    featureRow(icon: "2.circle", text: "Requires Accessibility + Input Monitoring permission (you'll be prompted)")
                    featureRow(icon: "3.circle", text: "Quit the separate Hyperkey app if it's running, to avoid conflicts")
                    featureRow(icon: "4.circle", text: "Normal Caps Lock is restored automatically when you quit AIHelper")
                }
            } header: {
                Label("Notes", systemImage: "info.circle")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Keep Awake (Caffeine)

    private var caffeineSettings: some View {
        Form {
            Section {
                Toggle("Keep the Mac awake now", isOn: Binding(
                    get: { caffeine.isActive },
                    set: { _ in caffeine.toggle() }
                ))

                if caffeine.isActive {
                    HStack {
                        Text("Time remaining")
                        Spacer()
                        Text("\(caffeine.remainingText) left")
                            .font(.body.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }

                Picker("Duration", selection: $caffeine.durationHours) {
                    ForEach(CaffeineManager.minHours...CaffeineManager.maxHours, id: \.self) { hours in
                        Text("\(hours) hour\(hours == 1 ? "" : "s")").tag(hours)
                    }
                }
                .disabled(caffeine.isActive)
            } header: {
                Label("Keep Awake", systemImage: "cup.and.saucer")
            } footer: {
                Text("Keeps the display awake for the chosen duration so the screen saver never starts and the Mac won't lock on its own, then lets it sleep normally again — like the Caffeine app, built in. Stop it to change the duration.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    featureRow(icon: "display", text: "Keeps the screen on so it won't lock on its own")
                    featureRow(icon: "menubar.arrow.up.rectangle", text: "Menu-bar mic fills in while it's active")
                    featureRow(icon: "timer", text: "Turns itself off automatically after the duration")
                    featureRow(icon: "bolt.slash", text: "No special permissions required")
                }
            } header: {
                Label("How it works", systemImage: "info.circle")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Development Machines

    /// Sidebar subtitle reflecting the number of hosts found in `~/.ssh/config`.
    private var devMachinesSubtitle: String {
        let count = devMachinesViewModel.hosts.count
        if count == 0 { return "From ~/.ssh/config" }
        return "\(count) host\(count == 1 ? "" : "s") in ~/.ssh/config"
    }

    private var developmentMachinesSettings: some View {
        DevelopmentMachinesListView(viewModel: devMachinesViewModel)
    }

    // MARK: - Transcription History

    private var filteredTranscriptions: [Transcription] {
        var items = transcriptionStore.transcriptions

        if let filter = historyModeFilter {
            items = items.filter { $0.mode == filter }
        }

        if !historySearchText.isEmpty {
            let query = historySearchText.lowercased()
            items = items.filter {
                $0.text.lowercased().contains(query) ||
                ($0.rawTranscription?.lowercased().contains(query) ?? false) ||
                ($0.promptUsed?.lowercased().contains(query) ?? false)
            }
        }

        return items
    }

    private var transcriptionHistoryView: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search...", text: $historySearchText)
                        .textFieldStyle(.plain)
                }
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
                .frame(maxWidth: 200)

                Picker("Mode", selection: $historyModeFilter) {
                    Text("All").tag(nil as TranscriptionMode?)
                    ForEach([TranscriptionMode.transcription, .email, .formatting], id: \.self) { mode in
                        Text(mode.displayName).tag(mode as TranscriptionMode?)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 350)

                Spacer()

                Text(ByteCountFormatter.string(fromByteCount: Int64(AudioFileManager.totalStorageBytes()), countStyle: .file))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(role: .destructive) {
                    audioPlayer.stop()
                    transcriptionStore.clearAll()
                } label: {
                    Label("Delete All", systemImage: "trash")
                        .font(.caption)
                }
                .disabled(transcriptionStore.transcriptions.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if filteredTranscriptions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No transcriptions")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    if !historySearchText.isEmpty || historyModeFilter != nil {
                        Text("Try different search terms or filters")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredTranscriptions) { transcription in
                            TranscriptionHistoryRow(
                                transcription: transcription,
                                isExpanded: expandedTranscriptionId == transcription.id,
                                audioPlayer: audioPlayer,
                                onToggleExpand: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        if expandedTranscriptionId == transcription.id {
                                            expandedTranscriptionId = nil
                                        } else {
                                            expandedTranscriptionId = transcription.id
                                        }
                                    }
                                },
                                onCopy: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(transcription.text, forType: .string)
                                },
                                onDelete: {
                                    if audioPlayer.currentTranscriptionId == transcription.id {
                                        audioPlayer.stop()
                                    }
                                    withAnimation {
                                        transcriptionStore.remove(transcription)
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private let repositoryURL = URL(string: "https://github.com/hendricius/aihelper")!

    /// App version read from the bundle (never hardcoded).
    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build, !build.isEmpty, build != short {
            return "Version \(short) (\(build))"
        }
        return "Version \(short)"
    }

    private var aboutView: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("AIHelper")
                .font(.title)

            Text(appVersion)
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Open source · Released under the MIT License")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text("Created by Hendrik Kleinwächter")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                Link("GitHub", destination: repositoryURL)
                Link("MIT License", destination: URL(string: "https://opensource.org/licenses/MIT")!)
            }
            .font(.caption)
            .padding(.top, 4)
        }
        .padding()
    }
}

// MARK: - History Row

struct TranscriptionHistoryRow: View {
    let transcription: Transcription
    let isExpanded: Bool
    @ObservedObject var audioPlayer: AudioPlayerManager
    let onToggleExpand: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    private var isPlayingThis: Bool {
        audioPlayer.isPlaying && audioPlayer.currentTranscriptionId == transcription.id
    }

    private var hasAudio: Bool {
        transcription.audioFileName != nil
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed row
            HStack(spacing: 8) {
                // Play/stop button
                Button {
                    if let fileName = transcription.audioFileName {
                        audioPlayer.togglePlayPause(fileName: fileName, transcriptionId: transcription.id)
                    }
                } label: {
                    Image(systemName: isPlayingThis ? "stop.circle.fill" : (hasAudio ? "play.circle.fill" : "waveform.slash"))
                        .font(.title3)
                        .foregroundColor(isPlayingThis ? .red : (hasAudio ? .accentColor : .secondary.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .disabled(!hasAudio)

                // Mode badge
                Text(transcription.mode.displayName)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(modeBadgeColor.opacity(0.15))
                    .foregroundColor(modeBadgeColor)
                    .cornerRadius(4)

                if transcription.formattingApplied {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }

                if let prompt = transcription.promptUsed {
                    Text(prompt)
                        .font(.caption2)
                        .foregroundColor(.purple)
                        .lineLimit(1)
                }

                // Text preview
                Text(transcription.text)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Duration
                if let duration = transcription.audioDurationSeconds {
                    Text(String(format: "%.0fs", duration))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }

                // Relative date
                Text(Self.relativeDateFormatter.localizedString(for: transcription.date, relativeTo: Date()))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 40, alignment: .trailing)

                // Copy button
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy")

                // Delete button
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete")

                // Expand chevron
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggleExpand)

            // Expanded details
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    // Playback progress bar
                    if isPlayingThis {
                        ProgressView(value: audioPlayer.currentTime, total: max(audioPlayer.duration, 0.01))
                            .tint(.accentColor)
                    }

                    // Raw transcription
                    if let raw = transcription.rawTranscription {
                        detailBlock(title: "Raw Text", content: raw)
                    }

                    // Original email context
                    if transcription.mode == .email, let context = transcription.originalContext {
                        detailBlock(title: "Original Email", content: context)
                    }

                    // Full output
                    detailBlock(title: "Output", content: transcription.text)

                    // API details grid
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Details")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)

                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], alignment: .leading, spacing: 4) {
                            if let duration = transcription.audioDurationSeconds {
                                detailCell(label: "Recording", value: String(format: "%.1fs", duration))
                            }
                            if let size = transcription.audioFileSizeBytes {
                                detailCell(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            }
                            if let ms = transcription.transcriptionDurationMs {
                                detailCell(label: "Transcription", value: "\(ms)ms")
                            }
                            if let ms = transcription.formattingDurationMs {
                                detailCell(label: "Formatting", value: "\(ms)ms")
                            }
                            if let engine = transcription.transcriptionEngine {
                                detailCell(label: "Engine", value: engine)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)

                    // API call logs
                    if let log = transcription.transcriptionAPILog {
                        apiCallLogView(title: "Transcription API", log: log)
                    }

                    if let log = transcription.formattingAPILog {
                        apiCallLogView(title: "Formatting API", log: log)
                    }

                    // Copy debug summary
                    HStack {
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(transcription.debugSummary(), forType: .string)
                        } label: {
                            Label("Debug-Info kopieren", systemImage: "doc.on.clipboard")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }

    private var modeBadgeColor: Color {
        switch transcription.mode {
        case .transcription: return .blue
        case .email: return .green
        case .formatting: return .orange
        case .casualMessage: return .purple
        }
    }

    @State private var expandedLogSections: Set<String> = []

    private func apiCallLogView(title: String, log: APICallLog) -> some View {
        let requestKey = "\(title)-request"
        let responseKey = "\(title)-response"

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .font(.caption)
                    .foregroundColor(.blue)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(log.statusCode)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(log.statusCode == 200 ? .green : .red)
                    .fontWeight(.bold)
                Text("\(log.durationMs)ms")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Endpoint
            Text(log.endpoint)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)

            // Request summary (always visible)
            Text(log.requestSummary)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)

            // Request body (collapsible, only if available)
            if let requestBody = log.requestBody {
                collapsibleJSONSection(
                    title: "Request Body",
                    content: requestBody,
                    key: requestKey
                )
            }

            // Response body (collapsible)
            collapsibleJSONSection(
                title: "Response",
                content: log.responseBody,
                key: responseKey
            )
        }
        .padding(8)
        .background(Color.blue.opacity(0.05))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.blue.opacity(0.15), lineWidth: 1)
        )
    }

    private func collapsibleJSONSection(title: String, content: String, key: String) -> some View {
        let isExpanded = expandedLogSections.contains(key)

        return VStack(alignment: .leading, spacing: 2) {
            Button {
                if expandedLogSections.contains(key) {
                    expandedLogSections.remove(key)
                } else {
                    expandedLogSections.insert(key)
                }
            } label: {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.caption2)
                        .fontWeight(.medium)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    Text(formatJSON(content))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 250)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(4)
            }
        }
    }

    private func formatJSON(_ string: String) -> String {
        guard let data = string.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: prettyData, encoding: .utf8) else {
            return string
        }
        return pretty
    }

    private func detailBlock(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            Text(content)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(4)
        }
    }

    private func detailCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
        }
    }
}

// MARK: - FlowLayout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)

        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalWidth = max(totalWidth, currentX - spacing)
            totalHeight = currentY + lineHeight
        }

        return (CGSize(width: totalWidth, height: totalHeight), positions)
    }
}

#Preview {
    SettingsView()
        .environmentObject(TranscriptionStore())
}
