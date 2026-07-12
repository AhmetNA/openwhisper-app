#!/bin/bash
# mic-guard: when the OnePlus buds NEWLY connect and macOS auto-grabs them as the
# system mic (HFP 16kHz, which breaks OpenWhisper + muffles playback), move the
# input back to the MacBook mic. Only fires on absent->present transition, so it
# will NOT fight a deliberate mid-session choice to use the buds as mic.
SAS=/opt/homebrew/bin/SwitchAudioSource
BUDS="OnePlus Nord Buds 3r"
MAC="MacBook Pro Microphone"
STATE="$HOME/.local/state/micguard.state"

[ -x "$SAS" ] || exit 0

present=0
"$SAS" -a -t input 2>/dev/null | grep -qF "$BUDS" && present=1

prev=0
[ -f "$STATE" ] && prev=$(cat "$STATE" 2>/dev/null)

if [ "$present" = "1" ] && [ "$prev" = "0" ]; then
  # buds just connected — give macOS a moment to auto-assign, then correct it
  sleep 2
  cur=$("$SAS" -c -t input 2>/dev/null)
  if [ "$cur" = "$BUDS" ]; then
    "$SAS" -s "$MAC" -t input >/dev/null 2>&1
    logger -t micguard "buds connected and grabbed mic -> switched input to $MAC"
  fi
fi

echo "$present" > "$STATE"
