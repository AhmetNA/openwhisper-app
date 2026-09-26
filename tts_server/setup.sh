#!/bin/bash
# One-time install of Jarvis's local voice (OmniVoice on MLX). Run again after editing
# requirements.txt. Creates a Python 3.12 venv in ~/Library/Application Support/OpenWhisper/tts
# and downloads the model (~2 GB) into the Hugging Face cache. build.sh keeps server.py and
# jarvis_ref.wav there up to date; it never touches the venv.
set -e
cd "$(dirname "$0")"

DEST="$HOME/Library/Application Support/OpenWhisper/tts"
mkdir -p "$DEST"

if ! command -v uv >/dev/null; then
    echo "ERROR: uv is required (brew install uv)"
    exit 1
fi

echo "==> Creating venv in $DEST/.venv"
uv venv --allow-existing --python 3.12 "$DEST/.venv"
uv pip install --python "$DEST/.venv/bin/python" -r requirements.txt

cp server.py jarvis_ref.wav "$DEST/"

echo "==> Downloading OmniVoice and checking a Turkish test sentence..."
(cd "$DEST" && "$DEST/.venv/bin/python" - <<'PY'
import sys, time
sys.path.insert(0, ".")
import server
started = time.time()
server.load()
if not server.state["ready"]:
    sys.exit(f"model failed to load: {server.state['error']}")
wav = server.synthesize("Tamamdır, patron.", "tr")
print(f"OK: {len(wav)} bytes of audio, {time.time() - started:.1f}s including load")
PY
)
echo "Done. Jarvis starts the voice server itself; nothing else to run."
