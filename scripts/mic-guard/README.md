# mic-guard

Keeps OpenWhisper dictation working when Bluetooth earbuds are connected.

## The problem

**OpenWhisper's in-app input-device picker only works on "System Default".**
Selecting a device by name (e.g. "MacBook Pro Microphone") does not capture —
in testing, only the **System Default** option produces working dictation. So
the app effectively always follows the **macOS system default input device**,
and the only reliable way to choose its mic is to control the OS default.

> **Set OpenWhisper's input to "System Default"** and manage the OS default
> input externally (that's what this agent does).

When Bluetooth
earbuds (e.g. OnePlus Nord Buds) are the default mic, macOS runs them in **HFP
mode — 16 kHz mono, telephone quality**. That:

- degrades / breaks Whisper transcription, and
- muffles any simultaneous audio playback (Netflix, music, etc.),

because Bluetooth earbuds physically can't do hi-fi A2DP playback and mic input
at the same time. macOS also tends to **auto-grab the earbuds as the mic every
time they reconnect**, so the problem keeps coming back.

## The fix

A launchd agent that, **only when the buds newly connect** and macOS grabs them
as the mic, switches the system input back to the MacBook mic. It does **not**
fight a deliberate mid-session choice to use the buds as mic.

Requires [`switchaudio-osx`](https://github.com/deweller/switchaudio-osx):

```bash
brew install switchaudio-osx
```

## Install

```bash
# 1. script
mkdir -p ~/.local/bin ~/.local/state
cp mic-guard.sh ~/.local/bin/mic-guard.sh
chmod +x ~/.local/bin/mic-guard.sh

# 2. launch agent (edit the plist path if your username differs)
cp com.raja.micguard.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.raja.micguard.plist
```

Disable anytime:

```bash
launchctl unload ~/Library/LaunchAgents/com.raja.micguard.plist
```

## Handy aliases (optional, add to `~/.zshrc`)

```bash
alias micfix='SwitchAudioSource -s "MacBook Pro Microphone" -t input'   # mic -> MacBook
alias micbuds='SwitchAudioSource -s "OnePlus Nord Buds 3r" -t input'    # mic -> buds
alias micnow='SwitchAudioSource -c -t input'                           # show current
```

## Notes

- Device names in `mic-guard.sh` (`OnePlus Nord Buds 3r`, `MacBook Pro
  Microphone`) are hardcoded — change them for your hardware. List names with
  `SwitchAudioSource -a -t input`.
- Poll interval is 10s (`StartInterval` in the plist); it only acts on an
  absent→present transition of the buds.
