# Jarvis

<p align="center">
  <strong>Fast, private, local voice-to-text for macOS.</strong><br>
  Speak anywhere you can type. Jarvis transcribes on your Mac and pastes the result at the active cursor.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-111827?style=flat-square&logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-M1%E2%80%93M4-f97316?style=flat-square&logo=apple&logoColor=white" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-5.10-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 5.10">
  <img src="https://img.shields.io/badge/WhisperKit-CoreML-0f766e?style=flat-square" alt="WhisperKit CoreML">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-22c55e?style=flat-square" alt="MIT License"></a>
</p>

Jarvis is a menu-bar dictation app for Apple Silicon Macs. It uses [WhisperKit](https://github.com/argmaxinc/WhisperKit) and Core ML for local transcription, then optionally uses [Ollama](https://ollama.com/) on `localhost` to remove filler words and improve punctuation.

Your microphone audio and transcript stay on your Mac during normal dictation. Spotify integration is optional and is the only feature that communicates with an external service.

## Highlights

- **Local transcription:** Whisper runs on-device through Core ML and the Neural Engine.
- **Extensible local STT providers:** providers are discovered from bundled JSON manifests and
  `~/Library/Application Support/OpenWhisper/STTProviders`. A provider bridge only needs to accept
  `--check` / `--transcribe <wav>` and return JSON, so adding a compatible ASR does not require a
  Swift model-specific integration.
- **Natural dictation:** hold `Fn` / `Globe`, speak, and release to paste text at the cursor.
- **Hands-free mode:** press `Space` or `Enter` while holding `Fn` to lock recording.
- **Turkish-friendly cleanup:** local Ollama models can fix punctuation, filler words, and phrasing.
- **Flow bar:** a small live overlay shows recording, audio level, and transcription state.
- **Correction learning:** teach Jarvis recurring corrections from its settings window.
- **Voice reminders:** say commands such as “bana 10 dakika sonra toplantıyı hatırlat”.
- **Optional Spotify controls:** search, play, pause, skip, and use Liked Songs from voice commands.
- **Input-device selection:** automatic mode prefers a connected headset microphone and falls back to the built-in Mac microphone; manual selection is also available.
- **No cloud account required:** build and run the app locally with SwiftPM.

## How it works

```text
Fn / Globe
    ↓
Local microphone capture
    ↓
WhisperKit + Core ML transcription
    ↓
Optional Ollama cleanup (localhost)
    ↓
Accessibility API → text pasted into the active app
```

## Requirements

| Requirement | Details |
| --- | --- |
| Mac | Apple Silicon: M1, M2, M3, or M4 |
| macOS | 14.0 or newer |
| Build tools | Xcode Command Line Tools; the full Xcode app is not required |
| Optional cleanup | Ollama plus `gemma4:e2b-it-qat` or `qwen3.5:4b` |
| Optional Spotify | A Spotify Developer application and Spotify Premium for playback endpoints |

Intel Macs are not supported by the current build.

## Quick start

### 1. Install build tools

```bash
xcode-select --install
```

### 2. Install Ollama (recommended)

Ollama is not required for raw transcription, but it enables cleanup and the flexible part of reminder parsing.

```bash
brew install ollama
ollama pull gemma4:e2b-it-qat
# Optional slower alternative: ollama pull qwen3.5:4b
```

Ollama should be available at `http://localhost:11434` while Jarvis is running.

### 3. Build and install Jarvis

```bash
git clone https://github.com/AhmetNA/openwhisper-app.git
cd openwhisper-app
bash build.sh
```

`build.sh` builds with SwiftPM, creates `build/Jarvis.app`, signs it with an available Apple Development identity (or ad-hoc signs it), copies it to `/Applications`, and launches it. To build without copying to `/Applications`:

```bash
SKIP_INSTALL=1 bash build.sh
open build/Jarvis.app
```

### One-line update/install

After the repository is public, the following command clones or updates `~/.openwhisper`, builds the app, and installs it:

```bash
curl -fsSL https://raw.githubusercontent.com/AhmetNA/openwhisper-app/main/install.sh | bash
```

## First launch permissions

Jarvis is a menu-bar app, so it may not open a normal window at launch. Look for its microphone icon in the menu bar and open **Settings** from there.

Grant these permissions when macOS asks:

1. **Microphone:** required to record dictation.
2. **Accessibility:** required to detect the global `Fn` shortcut and paste text into other apps.
3. **Automation / Apple Events:** required only for Spotify controls and Apple Reminders integration.
4. **Notifications:** required for local reminder notifications.

For reliable `Fn` / `Globe` behavior, set **System Settings → Keyboard → Press 🌐 key to → Do Nothing**. Otherwise macOS may open the emoji picker instead of handing the key to Jarvis.

## Usage

### Push-to-talk

1. Focus any text field in Notes, Terminal, Slack, VS Code, a browser, or another app.
2. Hold `Fn` / `Globe` and speak.
3. Release the key. The transcription is cleaned (if enabled) and pasted at the cursor.

### Hands-free recording

Hold `Fn` and press `Space` or `Enter` once. Release `Fn` and continue speaking. Press `Space` or `Enter` again to stop and paste the transcription.

Press `Esc` while recording to cancel without transcribing or pasting.

After editing a pasted dictation, press `⌥⇧C` (Option–Shift–C) to compare the original pasted text with the current field and send reliable differences to **Onay Bekleyenler** (pending approvals).

### Raw and cleaned text

When cleanup is enabled, Jarvis keeps the raw Whisper result and the cleaned result for the latest pasted dictation. Use the swap shortcut shown in the app to replace the inserted version with the other one.

## Settings

The menu-bar settings panel includes:

- language selection, including Turkish and auto-detect;
- konuşma modeli seçimi (WhisperKit veya keşfedilen yerel STT sağlayıcıları) ve indirme durumu;
- Ollama cleanup toggle and model selection;
- microphone/input-device selection;
- launch-at-login and flow-bar preferences;
- learned correction management;
- Spotify Client ID/Secret and account connection.

### Adding an external local STT provider

Place a provider manifest and its bridge script in:

```text
~/Library/Application Support/OpenWhisper/STTProviders/
```

The manifest must contain `schemaVersion`, `id`, `displayName`, `bridge`, `supportedLanguages`,
and an optional `python` executable path. The bridge contract is deliberately small:

```text
python bridge.py --check
python bridge.py --transcribe /path/to/16k-mono.wav
```

`--check` must exit with status 0 when the model can be prepared. `--transcribe` must print
`{"text":"..."}` as its final JSON result. Jarvis discovers the provider on the next
launch and adds it to the model picker; no Swift model-specific code is required. The bridge is
responsible for model format, quantization, downloads, and its own local runtime.

## Optional Spotify setup

Spotify is deliberately opt-in. If you enable it:

1. Create an application in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard).
2. Add this exact redirect URI to the application:
   `http://127.0.0.1:43821/callback`
3. Enter the Client ID and Client Secret in **Jarvis → Settings → Spotify**.
4. Test the connection, then connect your Spotify account when you want account-scoped commands such as Liked Songs.

Credentials and refresh tokens are stored in the macOS Keychain, not in `UserDefaults` or the repository. Do not commit credentials to source control.

## Optional mic-guard script

`scripts/mic-guard/` contains an optional LaunchAgent helper for controlling the macOS system-default input device. It is not required for Jarvis's automatic mode, which selects the connected headset directly when recording starts. If enabled, the helper intentionally switches the macOS system default back to the Mac microphone, which affects other apps that follow the system default.

It requires [SwitchAudioSource](https://github.com/deweller/switchaudio-osx):

```bash
brew install switchaudio-osx
mkdir -p "$HOME/.local/bin" "$HOME/Library/LaunchAgents"
cp scripts/mic-guard/mic-guard.sh "$HOME/.local/bin/mic-guard.sh"
chmod +x "$HOME/.local/bin/mic-guard.sh"
cp scripts/mic-guard/com.openwhisper.micguard.plist "$HOME/Library/LaunchAgents/"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.openwhisper.micguard.plist"
```

Edit the device names at the top of `mic-guard.sh` for your own earbuds and built-in microphone.

## Development

```bash
cd openwhisper-app
swift build
swift run OpenWhisper
```

Build artifacts, downloaded Whisper models, and local runtime data are intentionally ignored by Git.

Before opening a pull request, please check:

```bash
git diff --check
swift build
```

## Privacy and limitations

- Raw audio transcription is performed locally by WhisperKit/Core ML.
- Cleanup and reminder fallback parsing use only a local Ollama server.
- Spotify commands can send search/account requests to Spotify when that integration is enabled.
- The first Whisper model run downloads the selected model from WhisperKit's model source.
- The app currently targets Apple Silicon and macOS 14+.
- There is no signed/notarized release artifact yet; source builds use your local signing identity or ad-hoc signing.

## Contributing

Issues and pull requests are welcome. Please include the macOS version, chip model, selected Whisper/Ollama models, and relevant console output when reporting a bug. Never include API credentials, OAuth tokens, or personal paths in a report.

## License

Jarvis is released under the [MIT License](LICENSE).
