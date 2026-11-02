#!/bin/bash
# Install Ahenk Cep in its own environment; runtime is offline.
set -e
cd "$(dirname "$0")"

DEST="$HOME/Library/Application Support/OpenWhisper/tts-ahenk"
mkdir -p "$DEST"

if ! command -v uv >/dev/null; then
    echo "ERROR: uv is required (brew install uv)"
    exit 1
fi

echo "==> Creating venv in $DEST/.venv"
uv venv --allow-existing --python 3.12 "$DEST/.venv"
uv pip install --python "$DEST/.venv/bin/python" -r requirements.txt

cp server.py NOTICE.md "$DEST/"
"$DEST/.venv/bin/python" - "$DEST" <<'PYDOWNLOAD'
import sys
from huggingface_hub import hf_hub_download
from pathlib import Path
import shutil
root = Path(sys.argv[1])
revision = "345c4cbb934815fa96ffd0d5061fd913237544bc"
for name in ("student.pt", "decoder.pt", "ahenk_cep.py"):
    source = hf_hub_download("ozgurguler/ahenk-cep-tr", name, revision=revision)
    target = root / name if name.endswith(".py") else root / "weights" / name
    target.parent.mkdir(exist_ok=True)
    shutil.copy2(source, target)
PYDOWNLOAD

echo "==> Downloading Ahenk Cep and checking a Turkish test sentence..."
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
echo "Done. Pick 'Yerel — Ahenk Cep (Türkçe)' in Settings › Sesli cevap › Ses sağlayıcı; Jarvis starts the server itself."
