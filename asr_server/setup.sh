#!/bin/bash
# One-time install of the alternative speech model (Qwen3-ASR 1.7B on MLX). Run again after
# editing requirements.txt. Creates a Python 3.12 venv in ~/Library/Application Support/OpenWhisper/asr
# and downloads the model (~2.5 GB) into the Hugging Face cache. build.sh keeps server.py there
# up to date; it never touches the venv.
set -e
cd "$(dirname "$0")"

DEST="$HOME/Library/Application Support/OpenWhisper/asr"
mkdir -p "$DEST"

if ! command -v uv >/dev/null; then
    echo "ERROR: uv is required (brew install uv)"
    exit 1
fi

echo "==> Creating venv in $DEST/.venv"
uv venv --allow-existing --python 3.12 "$DEST/.venv"
uv pip install --python "$DEST/.venv/bin/python" -r requirements.txt

cp server.py "$DEST/"

echo "==> Downloading Qwen3-ASR and checking it loads..."
(cd "$DEST" && HF_HUB_DISABLE_XET=1 "$DEST/.venv/bin/python" - <<'PY'
import sys, time
sys.path.insert(0, ".")
import server
started = time.time()
server.load()
if not server.state["ready"]:
    sys.exit(f"model failed to load: {server.state['error']}")
print(f"OK: {server.MODEL_ID} loaded in {time.time() - started:.1f}s")
PY
)
echo "Done. Pick 'Qwen3-ASR 1.7B' under Ayarlar › Konuşma modeli; Jarvis starts the server itself."
