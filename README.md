# AIHelper

A macOS menu-bar app for fast voice transcription and AI text formatting. Record with a
global hotkey, get an instant transcription, and optionally reformat it into a clean email
or casual message — all from the menu bar. Bring your own API key.

**Open source · MIT licensed · created by Hendrik Kleinwächter.**

## Download

Grab the latest pre-built app from the [Releases page](https://github.com/hendricius/aihelper/releases),
unzip it, and drag `AIHelper.app` into `/Applications`.

The app is not yet code-signed/notarized, so on first launch macOS Gatekeeper will block it.
Either **right-click the app → Open** (then confirm), or run:

```bash
xattr -dr com.apple.quarantine /Applications/AIHelper.app
```

Prefer to build it yourself? See [Setup](#setup).

## Recording shortcut · works great with Hyperkey

The default record shortcut is **⌃⌥⌘⇧R** (Control-Option-Command-Shift-R). That five-finger
chord is awkward on its own, so AIHelper works best with [Hyperkey](https://hyperkey.app):
map **Caps Lock** to act as the "hyper" key (⌃⌥⌘⇧), then just press **Caps Lock + R** to start
and stop recording (and **Caps Lock + C** for clipboard history).

## Features

- 🎙️ One-click / global-hotkey audio recording (`⌃⌥⌘⇧R`)
- ✍️ AI transcription with your choice of provider — **OpenAI** or **AI Coordinator** — selectable in Settings
- 📧 Reformat dictation into a professional email reply or a casual message
- 🗣️ Hands-free recording: start with a wake word, auto-stop with a stop word (runs locally)
- 🧠 Custom vocabulary to improve spelling of names and technical terms
- 📋 Clipboard history manager (`⌃⌥⌘⇧C`)
- 📜 Transcription history with audio playback and full API debug logging

## Requirements

- macOS 14.0 (Sonoma) or later
- An API key for at least one provider:
  - **OpenAI** — get a key at <https://platform.openai.com/api-keys>
  - **AI Coordinator** — get a key at <https://aicoordinator.spacebread.dev>
- To build from source: Xcode 15.0 or later

## Choosing a provider (bring your own key)

Open **Settings → API**. Enter your OpenAI key, your AI Coordinator key, or both, then pick
the **Active Provider** (OpenAI by default). The active provider is used for both transcription
and formatting. Both providers speak the same OpenAI-compatible API shape; only the endpoint,
key, and model differ.

## Setup (build from source)

1. Clone the repository:
   ```bash
   git clone https://github.com/hendricius/aihelper.git
   cd aihelper
   ```

2. (Optional) Preload an API key from a `.env` file:
   ```bash
   cp .env.example .env
   ```
   Edit `.env` and fill in the key(s) for the provider(s) you use:
   ```
   OPENAI_API_KEY=sk-your-openai-key-here
   AIC_API_KEY=your-aicoordinator-key-here
   ```
   `make load-env` (run automatically by `make build`) writes these into the app's settings.
   You can also just type the key(s) into the app: **Settings → API**.

3. Build and run:
   ```bash
   make open
   ```

## Available commands

| Command | Description |
|---------|-------------|
| `make build` | Build the debug version |
| `make open` | Build and launch the app |
| `make clean` | Clean build artifacts |
| `make install` | Install to /Applications |
| `make load-env` | Load API key(s) from `.env` into the app's settings |

## Permissions

- **Microphone** — required for audio recording (System Settings → Privacy & Security → Microphone)
- **Accessibility** — required for the global keyboard shortcuts (System Settings → Privacy & Security → Accessibility)
- **Speech Recognition** — required for the wake-word / stop-word hands-free mode (runs locally)

## Project structure

```
AIHelper/
├── AIHelperApp.swift                  # Entry point, menu bar setup
├── AppDelegate.swift                  # App lifecycle, global hotkeys
├── ContentView.swift                  # Menu-bar popover UI
├── SettingsView.swift                 # Settings (API, vocabulary, wake/stop word, history, about)
├── APIProvider.swift                  # OpenAI / AI Coordinator provider abstraction
├── WhisperService.swift               # Audio transcription (provider-routed)
├── FormattingService.swift            # Email / message formatting (provider-routed)
├── TranscriptionServiceRouter.swift   # Transcription routing + timeout
├── RecordingManager.swift             # Orchestrates recording + transcription
├── WakeWordDetector.swift / StopWordDetector.swift  # Hands-free recording
├── ClipboardHistory*.swift            # Clipboard history manager
└── Models/                            # Data models
```

## License

MIT — see [LICENSE](./LICENSE).
