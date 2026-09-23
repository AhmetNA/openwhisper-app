#!/bin/bash
set -euo pipefail

APP_SUPPORT="$HOME/Library/Application Support/OpenWhisper/ByT5"
VENV="$APP_SUPPORT/.venv"

mkdir -p "$APP_SUPPORT"
if command -v uv >/dev/null 2>&1; then
    uv venv --python 3.12 "$VENV"
    uv pip install --python "$VENV/bin/python" \
        'torch>=2.4,<3' 'transformers>=4.45,<6' 'safetensors>=0.4,<1'
else
    python3 -m venv "$VENV"
    "$VENV/bin/python" -m pip install \
        'torch>=2.4,<3' 'transformers>=4.45,<6' 'safetensors>=0.4,<1'
fi

"$VENV/bin/python" - <<'PY'
from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

model_id = "erdemKocaogluu/byt5-small-tr-normalizer"
AutoTokenizer.from_pretrained(model_id)
AutoModelForSeq2SeqLM.from_pretrained(model_id)
print("ByT5 Turkish Normalizer indirildi ve hazır.")
PY
