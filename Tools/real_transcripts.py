"""Collects real Whisper transcripts of your own dictation for the LLM comparison.

    python3 Tools/real_transcripts.py OUT_FILE [COUNT]

Reads every `[OpenWhisper] Raw:` line from the saved recordings' logs, the decision-model log
archive and the live log, drops duplicates and anything under three words, and writes a fixed
random sample (same seed every time, so runs stay comparable) one transcript per line.
Nothing leaves the Mac; the file is written wherever OUT_FILE points.
"""
import random
import re
import sys
from pathlib import Path

HOME = Path.home()
REPO = Path(__file__).resolve().parents[2]
SOURCES = [
    *sorted((HOME / "Library/Application Support/OpenWhisper/Recordings").glob("*.log")),
    REPO / "decision_model/data/raw/openwhisper-archive.log",
    Path("/tmp/openwhisper.log"),
]

out_file = Path(sys.argv[1])
count = int(sys.argv[2]) if len(sys.argv) > 2 else 80

seen = {}
for source in SOURCES:
    if not source.exists():
        continue
    for raw in re.findall(r"\[OpenWhisper\] Raw: (.+)", source.read_text(encoding="utf-8", errors="replace")):
        raw = raw.strip()
        if len(raw.split()) >= 3:
            seen.setdefault(raw, None)

transcripts = sorted(seen)
random.Random(42).shuffle(transcripts)
sample = transcripts[:count]
out_file.write_text("\n".join(sample) + "\n", encoding="utf-8")
print(f"{len(sample)} of {len(transcripts)} real transcripts → {out_file}")
