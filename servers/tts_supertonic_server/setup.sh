#!/bin/bash
# Installs a separate runtime and the pinned Supertonic 3 Core ML files (int4, ~105 MB).
# Model: FluidInference/supertonic-3-coreml, derived from Supertone/supertonic-3 (OpenRAIL-M).
set -euo pipefail
cd "$(dirname "$0")"
DEST="$HOME/Library/Application Support/OpenWhisper/tts-supertonic"
command -v uv >/dev/null || { echo 'uv is required (brew install uv)'; exit 1; }
mkdir -p "$DEST"
uv venv --allow-existing --python 3.12 "$DEST/.venv"
uv pip install --python "$DEST/.venv/bin/python" -r requirements.txt
HF_HUB_DISABLE_XET=1 "$DEST/.venv/bin/python" - "$DEST/model" <<'PY'
import sys
from huggingface_hub import snapshot_download
snapshot_download(
    "FluidInference/supertonic-3-coreml",
    revision="2b5b939dfa1bca362c5212dcafeb8aadde90b1bc",
    local_dir=sys.argv[1],
    allow_patterns=["TextEncoder_v2.mlpackage/**", "DurationPredictor_v2.mlpackage/**",
                    "Vocoder.mlpackage/**",
                    "VectorEstimatorVariants/VectorEstimator_v2_L128_int4.mlpackage/**",
                    "tts.json", "unicode_indexer.json", "voice_styles/M1.json", "LICENSE"],
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
data = server.synthesize("Tamamdır, efendim. Supertonic internetsiz konuşmaya hazır.")
with wave.open(io.BytesIO(data)) as wav:
    assert wav.getnframes() > 0 and wav.getnchannels() == 1
    print(f"OK: {wav.getnframes() / wav.getframerate():.2f}s audio at {wav.getframerate()} Hz")
PY
)
echo 'Installed. Select Yerel — Supertonic 3 (Türkçe) in voice settings.'
