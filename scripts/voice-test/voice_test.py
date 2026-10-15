#!/usr/bin/env python3
"""Automatic voice tests: speaks each scenario into the running Jarvis and checks the log.

Every scenario's sentence is synthesized ("Hey Jarvis" in an English voice, the command in
Turkish), normalized to a real mic's level and played into the microphone stream through
`openwhisper://voicetest/play` (see `VoiceTestInjector.swift`). The wake word, recording,
transcription, routing and the action itself run for real; the scenario passes when its
`expect` patterns show up in /tmp/openwhisper.log and none of its `forbid` patterns do.
Nothing is pasted while a test runs, and the real mic is muted.

    python3 scripts/voice-test/voice_test.py              # quick smoke set (~1 min)
    python3 scripts/voice-test/voice_test.py timer video  # only names containing these words
    python3 scripts/voice-test/voice_test.py --full       # every safe scenario (several minutes)
    python3 scripts/voice-test/voice_test.py --all        # also the ones marked unsafe
    python3 scripts/voice-test/voice_test.py --say "Şarj kaç?"   # one-off, prints the log

Scenarios: scenarios.json next to this file. Fields: name, say, expect (regexes, all must
match), forbid (regexes), timeout (s), safe (false = changes something hard to undo; skipped
without --all), speaker ("user" = treat the voice as the enrolled user's, "real" = keep the
speaker checks on), voice (per-scenario TTS voice), focus (what the keyboard
focus counts as: "editable" = a text field, the default, "notEditable" = nothing to type into,
"unknown"; decides dictation vs. answer), setup / teardown (shell commands), skip_if (shell command; exit 0 = skip), note, wake (false = no "Hey Jarvis" prefix).
"""

import argparse
import array
import json
import math
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid
import wave
from pathlib import Path

LOG = Path("/tmp/openwhisper.log")
CLIP_DIR = Path.home() / "Library/Application Support/OpenWhisper/VoiceTests"
DOMAIN = "com.openwhisper.app"
RATE = 48_000
HERE = Path(__file__).resolve().parent
# Real speech on the built-in mic, raw: about -50…-35 dBFS RMS (`[AudioEngine] Input level
# summary`, `[Speakers] own … @ -35 dBFS`). Louder clips would clip after the listener's ×4 gain.
TARGET_SPEECH_DBFS = -36.0
# A session is over when its latency summary is logged; replies may still be playing after it.
SESSION_DONE = re.compile(r"\[Latency\] Kritik süre|\[WakeWord\] Weak detection .* rejected|discarding session")


POCKET = "http://127.0.0.1:8772/speak"


def synth(text: str, voice: str, out: Path) -> list[int]:
    """`voice` is a macOS voice (`say -v '?'`) or "pocket": the Turkish Pocket TTS server
    Jarvis itself speaks with (runs while it is the selected reply voice). Whisper misheard
    Yelda's short phrases ("Saat kaç?" → "THUG CUTCH"); Pocket sounds closer to a person."""
    if voice == "pocket":
        request = urllib.request.Request(POCKET, data=json.dumps({"text": text}).encode(),
                                         headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = out.with_suffix(".pocket.wav")
            raw.write_bytes(response.read())
        subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", str(raw), str(out)], check=True)
    else:
        subprocess.run(["say", "-v", voice, "-o", str(out), "--file-format=WAVE",
                        f"--data-format=LEI16@{RATE}", text], check=True)
    with wave.open(str(out)) as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1
        samples = array.array("h", w.readframes(w.getnframes()))
    return list(samples)


def build_clip(command: str, wake: bool, wake_voice: str, voice: str, gap: float) -> Path:
    CLIP_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        parts: list[int] = [0] * int(RATE * 0.3)
        if wake:
            parts += synth("Hey Jarvis", wake_voice, Path(tmp) / "wake.wav")
            parts += [0] * int(RATE * gap)
        parts += synth(command, voice, Path(tmp) / "cmd.wav")
        parts += [0] * int(RATE * 0.5)
    # Normalize on the voiced part only, so leading and trailing silence don't skew it.
    voiced = [s for s in parts if abs(s) > 300] or [1]
    rms = math.sqrt(sum(s * s for s in voiced) / len(voiced)) / 32768
    gain = 10 ** (TARGET_SPEECH_DBFS / 20) / max(rms, 1e-9)
    peak = max(abs(s) for s in parts) / 32768 * gain
    if peak > 0.5:
        gain *= 0.5 / peak
    scaled = array.array("h", (max(-32768, min(32767, int(s * gain))) for s in parts))
    path = CLIP_DIR / f"vt-{uuid.uuid4().hex[:8]}.wav"
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(scaled.tobytes())
    return path


def open_url(url: str) -> None:
    subprocess.run(["open", "-g", url], check=True)


def read_from(offset: int) -> str:
    with LOG.open("rb") as f:
        f.seek(offset)
        return f.read().decode("utf-8", "replace")


def wait_until_listening(timeout: float = 120) -> None:
    """After a rebuild (`./build.sh`) Jarvis needs a moment before the wake listener runs."""
    if subprocess.run(["pgrep", "-x", "OpenWhisper"], capture_output=True).returncode != 0:
        sys.exit("Jarvis is not running (open /Applications/Jarvis.app)")
    text = LOG.read_text("utf-8", "replace")
    last_launch = text.rfind("applicationDidFinishLaunching")
    if text.find("[WakeWord] Listening on", max(last_launch, 0)) >= 0:
        return
    print("Waiting for the wake listener…")
    deadline = time.time() + timeout
    while time.time() < deadline:
        if "[WakeWord] Listening on" in LOG.read_text("utf-8", "replace")[last_launch:]:
            return
        time.sleep(1)
    sys.exit("The wake listener never started (see /tmp/openwhisper.log)")


def run_shell(commands: list[str]) -> None:
    for command in commands:
        subprocess.run(command, shell=True, check=False)


def run_scenario(sc: dict, args) -> tuple[bool, str, str]:
    """The mic stays muted between scenarios (the injector is ended only after the whole run):
    giving it back in between let room talk start a session that swallowed the next clip."""
    run_shell(sc.get("setup", []))
    clip = build_clip(sc["say"], sc.get("wake", True), args.wake_voice, sc.get("voice", args.voice), args.gap)
    marker = uuid.uuid4().hex[:8]
    offset = LOG.stat().st_size
    speaker = sc.get("speaker", "user")
    # Whether Jarvis answers or types depends on the keyboard focus (`[Addressee]`); the app
    # takes it from the scenario instead of whatever the developer has in front.
    focus = sc.get("focus", "editable")
    open_url(f"openwhisper://voicetest/play?file={clip.name}&speaker={speaker}&focus={focus}&id={marker}")
    expects = [re.compile(p) for p in sc.get("expect", [])]
    forbids = [re.compile(p) for p in sc.get("forbid", [])]
    deadline = time.time() + sc.get("timeout", 25)
    log = ""
    verdict, why = None, ""
    done_at = None
    while time.time() < deadline:
        time.sleep(0.5)
        log = read_from(offset)
        bad = next((f.pattern for f in forbids if f.search(log)), None)
        if bad:
            verdict, why = False, f"forbidden: {bad}"
            break
        missing = [e.pattern for e in expects if not e.search(log)]
        if SESSION_DONE.search(log) and done_at is None:
            done_at = time.time()
        if not missing and done_at is not None:
            # Let late lines (a reply, a follow-up window) land so `forbid` can still catch them.
            if time.time() - done_at >= sc.get("settle", 2):
                verdict, why = True, ""
                break
        elif done_at is not None and time.time() - done_at > sc.get("settle", 2) + 3:
            verdict, why = False, "missing: " + ", ".join(missing)
            break
    if verdict is None:
        missing = [e.pattern for e in expects if not e.search(log)]
        verdict, why = False, "timeout" + (" — missing: " + ", ".join(missing) if missing else "")
    run_shell(sc.get("teardown", []))
    clip.unlink(missing_ok=True)
    return verdict, why, log


def summarize(log: str) -> str:
    keep = re.compile(r"\[(WakeWord\] (Detected|Weak|Candidate)|OpenWhisper\] Raw|Route|Addressee|FollowUp|Voice\]|VoiceTest|Timer|System|Result|Speakers)")
    return "\n".join("      " + l[26:200] for l in log.splitlines() if keep.search(l))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("filters", nargs="*", help="run scenarios whose name contains any of these")
    parser.add_argument("--all", action="store_true", help="include scenarios marked safe: false")
    parser.add_argument("--full", action="store_true", help="every scenario, not just the smoke set")
    parser.add_argument("--say", help="one-off sentence instead of the scenario file")
    parser.add_argument("--voice", default="pocket",
                        help="'pocket' (Jarvis's Turkish TTS server, default) or a macOS voice such as Yelda")
    parser.add_argument("--wake-voice", default="Samantha", help="macOS voice for 'Hey Jarvis'")
    parser.add_argument("--gap", type=float, default=0.25, help="pause after 'Hey Jarvis' in seconds")
    parser.add_argument("--scenarios", type=Path, default=HERE / "scenarios.json")
    parser.add_argument("-v", "--verbose", action="store_true", help="print the key log lines of every scenario")
    args = parser.parse_args()

    if args.say:
        scenarios = [{"name": "say", "say": args.say, "expect": [r"\[OpenWhisper\] Raw:"], "timeout": 30}]
        args.verbose = True
    else:
        scenarios = json.loads(args.scenarios.read_text("utf-8"))
        if args.filters:
            scenarios = [s for s in scenarios if any(f.lower() in s["name"].lower() for f in args.filters)]
        elif not args.full:
            # A full run takes several minutes; by default only the quick smoke set runs.
            scenarios = [s for s in scenarios if s.get("smoke")]
        skipped = [s["name"] for s in scenarios if not s.get("safe", True) and not args.all]
        scenarios = [s for s in scenarios if s.get("safe", True) or args.all]
        if skipped:
            print(f"Skipping {len(skipped)} unsafe scenario(s) (use --all): {', '.join(skipped)}")

    wait_until_listening()
    if args.voice == "pocket":
        try:
            urllib.request.urlopen(POCKET.replace("/speak", "/health"), timeout=3)
        except OSError:
            print("Pocket TTS server not running; using Yelda (Ayarlar › Sesli cevap › Pocket TTS starts it)")
            args.voice = "Yelda"
    subprocess.run(["defaults", "write", DOMAIN, "voiceTestMode", "-bool", "true"], check=True)
    results = []
    try:
        for sc in scenarios:
            print(f"▶ {sc['name']}: “{sc['say']}”", flush=True)
            if sc.get("skip_if") and subprocess.run(sc["skip_if"], shell=True).returncode == 0:
                print("  ⏭  atlandı (skip_if)")
                continue
            ok, why, log = run_scenario(sc, args)
            results.append((sc["name"], ok, why))
            print(f"  {'✅ geçti' if ok else '❌ kaldı'}{'  — ' + why if why else ''}")
            if args.verbose or not ok:
                print(summarize(log))
            time.sleep(sc.get("pause", 2))
    finally:
        open_url("openwhisper://voicetest/end")
        subprocess.run(["defaults", "delete", DOMAIN, "voiceTestMode"], check=False, capture_output=True)
    passed = sum(ok for _, ok, _ in results)
    print(f"\n{passed}/{len(results)} geçti")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
