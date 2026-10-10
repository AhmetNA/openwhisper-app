#!/bin/bash
# One-time install of the default Pocket TTS Turkish voice (Settings › Sesli cevap). Run
# again after editing requirements.txt. Creates its own Python 3.12 venv in
# ~/Library/Application Support/OpenWhisper/tts-pocket and downloads the model (~440 MB) into the
# Hugging Face cache. It clones Jarvis from tts_server/jarvis_ref.wav. build.sh keeps server.py
# and the reference there up to date; it never touches the venv.
# Remove everything with: rm -rf "$HOME/Library/Application Support/OpenWhisper/tts-pocket"
set -e
cd "$(dirname "$0")"

DEST="$HOME/Library/Application Support/OpenWhisper/tts-pocket"
mkdir -p "$DEST"

if ! command -v uv >/dev/null; then
    echo "ERROR: uv is required (brew install uv)"
    exit 1
fi

echo "==> Creating venv in $DEST/.venv"
uv venv --allow-existing --python 3.12 "$DEST/.venv"
uv pip install --python "$DEST/.venv/bin/python" -r requirements.txt

cp server.py ../tts_server/jarvis_ref.wav "$DEST/"

echo "==> Downloading Pocket TTS Turkish and checking a Turkish test sentence..."
(cd "$DEST" && "$DEST/.venv/bin/python" - <<'PY'
import sys, time
sys.path.insert(0, ".")
import server
started = time.time()
server.load()
if not server.state["ready"]:
    sys.exit(f"model failed to load: {server.state['error']}")
wav = server.synthesize("Tamamdır, patron.")
print(f"OK: {len(wav)} bytes of audio, {time.time() - started:.1f}s including load")
PY
)
echo "Done. It is the default voice (Settings › Sesli cevap › Ses sağlayıcı); Jarvis starts the server itself."
