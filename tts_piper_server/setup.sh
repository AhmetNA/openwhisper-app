#!/bin/bash
# One-time install of Jarvis's English voice, Piper Jarvis (Settings › Sesli cevap). Run again
# after editing requirements.txt. Creates its own small Python 3.12 venv in
# ~/Library/Application Support/OpenWhisper/tts-piper and downloads the model (~63 MB) into the
# Hugging Face cache. build.sh keeps server.py there up to date; it never touches the venv.
# Remove everything with: rm -rf "$HOME/Library/Application Support/OpenWhisper/tts-piper"
set -e
cd "$(dirname "$0")"

DEST="$HOME/Library/Application Support/OpenWhisper/tts-piper"
mkdir -p "$DEST"

if ! command -v uv >/dev/null; then
    echo "ERROR: uv is required (brew install uv)"
    exit 1
fi
if [ ! -e /opt/homebrew/lib/libespeak-ng.dylib ]; then
    echo "ERROR: espeak-ng is required (brew install espeak-ng)"
    exit 1
fi

echo "==> Creating venv in $DEST/.venv"
uv venv --allow-existing --python 3.12 "$DEST/.venv"
uv pip install --python "$DEST/.venv/bin/python" -r requirements.txt

cp server.py "$DEST/"

echo "==> Downloading Piper Jarvis and checking an English test sentence..."
(cd "$DEST" && "$DEST/.venv/bin/python" - <<'PY'
import sys, time
sys.path.insert(0, ".")
import server
started = time.time()
server.load()
if not server.state["ready"]:
    sys.exit(f"model failed to load: {server.state['error']}")
wav = server.synthesize("Right away, sir. It is 2:05 in the afternoon.")
print(f"OK: {len(wav)} bytes of audio, {time.time() - started:.1f}s including load")
PY
)
echo "Done. Pick 'Yerel — Piper Jarvis (İngilizce)' in Settings › Sesli cevap › Ses sağlayıcı; Jarvis then answers in English."
