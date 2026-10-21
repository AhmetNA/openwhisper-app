#!/bin/bash
# Optional CPU-only Turkish ITN. No ASR/TTS model or Pynini is installed.
set -euo pipefail
cd "$(dirname "$0")"
DEST="${DAMGA_INSTALL_DIR:-$HOME/Library/Application Support/OpenWhisper/damga}"
command -v uv >/dev/null || { echo "uv gerekli: brew install uv"; exit 1; }
mkdir -p "$DEST"
uv venv --allow-existing --python 3.12 "$DEST/.venv"
uv pip install --python "$DEST/.venv/bin/python" --only-binary :all: -r requirements.txt
cp server.py "$DEST/"
"$DEST/.venv/bin/python" -c 'from damga import InverseNormalizer; assert InverseNormalizer(backend="native", repair_spelling=False).normalize("yüz elli lira") == "150 TL"'
echo "Hazır. Jarvis › Ayarlar › Türkçe sayı ve tarih biçimlendirme (Damga) anahtarını açın."
