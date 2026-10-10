#!/bin/bash
# Experimental, compare-only: installs Antalia-1 (PatientDesk's open Turkish TTS) so
# `scripts/tts-compare/compare.py antalia` can read the test sentences with it. The app doesn't
# use it. Everything goes into ~/Library/Application Support/OpenWhisper/tts-antalia: its own
# Python 3.12 venv (PyTorch), the Antalia code, the pinned BigVGAN source, and on first run the
# weights (~1.2 GB model + ~0.45 GB vocoder) in the Hugging Face cache.
# Remove everything with: rm -rf "$HOME/Library/Application Support/OpenWhisper/tts-antalia"
set -e
cd "$(dirname "$0")"

DEST="$HOME/Library/Application Support/OpenWhisper/tts-antalia"
BIGVGAN_COMMIT=7d2b454564a6c7d014227f635b7423881f14bdac
mkdir -p "$DEST"

if ! command -v uv >/dev/null; then
    echo "ERROR: uv is required (brew install uv)"
    exit 1
fi

if [ ! -d "$DEST/antalia" ]; then
    echo "==> Cloning Antalia code"
    git clone --depth 1 https://github.com/0daycloud/antalia "$DEST/antalia"
fi
if [ ! -d "$DEST/bigvgan" ]; then
    echo "==> Cloning BigVGAN at the pinned commit"
    git clone https://github.com/NVIDIA/BigVGAN "$DEST/bigvgan"
    git -C "$DEST/bigvgan" checkout -q "$BIGVGAN_COMMIT"
    patch -d "$DEST/bigvgan" -p4 < "$DEST/antalia/scripts/patches/bigvgan-huggingface-hub-1.patch"
fi

echo "==> Creating venv in $DEST/.venv"
uv venv --allow-existing --python 3.12 "$DEST/.venv"
uv pip install --python "$DEST/.venv/bin/python" -e "$DEST/antalia" \
    "torch>=2.8,<3" "torchaudio>=2.8,<3" librosa ninja matplotlib

cp server.py "$DEST/"

echo "==> Downloading Antalia-1 + BigVGAN and checking a Turkish test sentence..."
(cd "$DEST" && "$DEST/.venv/bin/python" - <<'PY'
import sys, time
sys.path.insert(0, ".")
import server
started = time.time()
server.load()
if not server.state["ready"]:
    sys.exit(f"model failed to load: {server.state['error']}")
t = time.time()
wav = server.synthesize("Tamamdır, patron.")
print(f"OK on {server.state['device']}: {len(wav)} bytes in {time.time() - t:.1f}s ({time.time() - started:.1f}s incl. load)")
PY
)
echo "Done. Compare: python3 scripts/tts-compare/compare.py --interleave"
