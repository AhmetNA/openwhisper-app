# mic-guard

Controls the macOS system-default microphone when Bluetooth earbuds are connected.

OpenWhisper's automatic input mode does not depend on this helper: it selects a
connected headset input directly at the start of a recording and otherwise uses
the built-in Mac microphone. This helper remains optional and affects other apps
that follow the macOS system default.

## The problem

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
as the system mic, switches the system input back to the MacBook mic. It does
not change OpenWhisper's direct automatic device selection, but it does change
the system default used by other applications.

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
cp com.openwhisper.micguard.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.openwhisper.micguard.plist
```

Disable anytime:

```bash
launchctl unload ~/Library/LaunchAgents/com.openwhisper.micguard.plist
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
- macOS does not expose a reliable standalone Bluetooth connection notification to this
  shell-only LaunchAgent. Its conservative fallback checks once per minute
  (`StartInterval` in the plist) and only acts on an absent→present transition of the buds.
  This removes five out of every six former idle wakeups; a newly connected buds pair can take
  up to one minute to be corrected.
