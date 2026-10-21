#!/bin/bash
# Installs a separate runtime and pinned Apache-2.0 Phonon 31m English model.
set -euo pipefail
cd "$(dirname "$0")"
DEST="$HOME/Library/Application Support/OpenWhisper/tts-phonon"
command -v uv >/dev/null || { echo 'uv is required'; exit 1; }
mkdir -p "$DEST"
uv venv --allow-existing --python 3.12 "$DEST/.venv"
uv pip install --python "$DEST/.venv/bin/python" -r requirements.txt
"$DEST/.venv/bin/python" - "$DEST/model" <<'PY'
import sys
from huggingface_hub import snapshot_download
snapshot_download(
    "gradium/phonon-31m-en",
    revision="52433c46975bfa13144c56204c9f4ee1c5b148aa",
    local_dir=sys.argv[1],
    allow_patterns=["config.json", "tokenizer.json", "model.q8.gguf",
                    "default-voice.safetensors", "README.md", "LICENSE*"],
)
PY
cp server.py "$DEST/"
(cd "$DEST" && HF_HUB_OFFLINE=1 "$DEST/.venv/bin/python" - <<'PY'
import io
import server
import wave
server.load()
if not server.state["ready"]:
    raise SystemExit(server.state["error"])
data = server.synthesize("Hello. Phonon is ready to speak offline.")
with wave.open(io.BytesIO(data)) as wav:
    assert wav.getnframes() > 0 and wav.getnchannels() == 1
    print(f"OK: {wav.getnframes() / wav.getframerate():.2f}s audio at {wav.getframerate()} Hz")
PY
)
echo 'Installed. Select Yerel — Phonon 31m (İngilizce) in voice settings.'
