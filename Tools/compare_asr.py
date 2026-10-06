"""Whisper (what the app wrote at the time) vs Qwen3-ASR on your saved recordings.

    "$HOME/Library/Application Support/OpenWhisper/asr/.venv/bin/python" Tools/compare_asr.py [OUT_TSV]

Needs asr_server/setup.sh. For every recording in ~/Library/Application Support/OpenWhisper/Recordings
whose log has a `Raw:` line, transcribes the .caf with Qwen3-ASR (with and without the glossary
as hotwords) and prints the three side by side with Qwen's speed. There is no reference text, so
you judge which is right. Whisper heard the app's processed audio (noise filter, echo cancel),
Qwen hears the saved recording, so Whisper has a slight edge on noisy clips.
"""
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

os.environ.setdefault("HF_HUB_OFFLINE", "1")
sys.path.insert(0, str(Path.home() / "Library/Application Support/OpenWhisper/asr"))
import server  # noqa: E402  the installed asr_server/server.py

RECORDINGS = Path.home() / "Library/Application Support/OpenWhisper/Recordings"
GLOSSARY = Path.home() / "Library/Application Support/OpenWhisper/glossary.txt"
out_tsv = Path(sys.argv[1]) if len(sys.argv) > 1 else None

glossary = [l.strip() for l in GLOSSARY.read_text(encoding="utf-8").splitlines()
            if l.strip() and not l.startswith("#")] if GLOSSARY.exists() else []
server.load()
if not server.state["ready"]:
    sys.exit(f"Qwen3-ASR did not load: {server.state['error']}")

import numpy as np  # noqa: E402
import soundfile as sf  # noqa: E402

rows, same, qwen_ms, audio_s = [], 0, 0.0, 0.0
for caf in sorted(RECORDINGS.glob("*.caf"), key=lambda p: p.stat().st_mtime):
    if ".partial" in caf.name or not caf.with_suffix(".log").exists():
        continue
    match = re.search(r"\[OpenWhisper\] Raw: (.+)", caf.with_suffix(".log").read_text(encoding="utf-8", errors="replace"))
    if not match:
        continue
    whisper = match.group(1).strip()
    with tempfile.NamedTemporaryFile(suffix=".wav") as wav:
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(caf), wav.name], check=True)
        audio, _ = sf.read(wav.name, dtype="float32")
    started = time.time()
    qwen = server.transcribe(np.asarray(audio), "tr", None)
    qwen_ms += (time.time() - started) * 1000
    audio_s += len(audio) / 16_000
    qwen_glossary = server.transcribe(np.asarray(audio), "tr", glossary)
    if len(qwen_glossary.split()) > server.max_plausible_words(len(audio) / 16_000):  # same guard as /transcribe
        qwen_glossary = server.transcribe(np.asarray(audio), "tr", None) + "  [sözlük sızdı → sözlüksüz]"
    norm = lambda s: re.sub(r"[^\w\s]", "", s.lower()).split()  # noqa: E731
    same += norm(whisper) == norm(qwen)
    rows.append((caf.stem[:8], f"{len(audio) / 16_000:.1f}s", whisper, qwen, qwen_glossary))
    print(f"\n{caf.stem[:8]} ({len(audio) / 16_000:.1f} s)\n  Whisper:          {whisper}\n  Qwen:             {qwen}\n  Qwen + sözlük:    {qwen_glossary}")

print(f"\n{len(rows)} recordings, {audio_s:.0f} s of audio. Whisper and Qwen agree word for word on {same}.")
print(f"Qwen3-ASR speed: {qwen_ms / max(len(rows), 1):.0f} ms per recording, {audio_s / (qwen_ms / 1000):.0f}x real time.")
if out_tsv:
    out_tsv.write_text("id\tduration\twhisper\tqwen\tqwen_glossary\n"
                       + "\n".join("\t".join(r) for r in rows) + "\n", encoding="utf-8")
    print(f"Table: {out_tsv}")
