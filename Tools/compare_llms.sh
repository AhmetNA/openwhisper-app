#!/bin/bash
# Runs the Turkish cleanup (20) and Spotify (97) eval sets against local Ollama models, with the
# app's own prompts, so a candidate can be compared to the current default before switching.
# Then the same on your real data: 80 real Whisper transcripts of your dictation (no expected
# answer; compared side by side, see real-side-by-side) and your own labelled Spotify sentences
# (decision_model/data/labels/spotify_intent.tsv).
#
#   Tools/compare_llms.sh                          # default + the four candidates from Settings
#   Tools/compare_llms.sh gemma4:e4b-it-qat lfm2.5:8b
#
# Models that aren't pulled are skipped (pull them first: ollama pull <model>). Every model is
# unloaded before the next so they don't share the 16 GB. Takes a few minutes per model.
set -e
cd "$(dirname "$0")/.."

MODELS=("$@")
[ ${#MODELS[@]} -eq 0 ] && MODELS=(gemma4:e4b-it-qat ministral-3:3b ministral-3:8b granite4.2:8b lfm2.5:8b)

OUT="${TMPDIR:-/tmp}/openwhisper-evals"
mkdir -p "$OUT"
echo "==> Building eval tools"
swiftc Tools/CleanupEval/main.swift Tools/SpotifyEval/Stubs.swift \
    OpenWhisper/Core/LLMCleanup.swift OpenWhisper/Core/GlossaryStore.swift \
    OpenWhisper/Core/MisheardWordDetector.swift OpenWhisper/Core/TranscriptSanitizer.swift \
    -o "$OUT/cleanup_eval"
swiftc Tools/SpotifyEval/main.swift Tools/SpotifyEval/Stubs.swift \
    OpenWhisper/Core/SpotifyManager.swift OpenWhisper/Core/SpotifyController.swift \
    OpenWhisper/Core/SpotifyWebAPI.swift OpenWhisper/Core/SpotifyRequestParser.swift \
    OpenWhisper/Core/LLMCleanup.swift OpenWhisper/Core/GlossaryStore.swift \
    OpenWhisper/Core/SystemVolume.swift OpenWhisper/Core/AudioDucker.swift \
    OpenWhisper/Core/MisheardWordDetector.swift OpenWhisper/Core/SetFitDecider.swift \
    OpenWhisper/Core/TranscriptSanitizer.swift -o "$OUT/spotify_eval"

SUMMARY="$OUT/summary-$(date +%Y%m%d-%H%M%S).txt"
REAL="$OUT/real_transcripts.txt"
LABELS="../decision_model/data/labels/spotify_intent.tsv"
python3 Tools/real_transcripts.py "$REAL" 80
for model in "${MODELS[@]}"; do
    if ! ollama list | awk 'NR>1 {print $1}' | grep -qx "$model"; then
        echo "--- $model is not pulled, skipping (ollama pull $model)" | tee -a "$SUMMARY"
        continue
    fi
    ollama ps | awk 'NR>1 {print $1}' | xargs -r -n1 ollama stop 2>/dev/null || true
    echo "==> $model: cleanup"
    "$OUT/cleanup_eval" "$model" | tee "$OUT/cleanup-$model.txt" | grep -m1 -E "correct [0-9]+/" | sed "s|^|cleanup: |" | tee -a "$SUMMARY"
    echo "==> $model: spotify"
    "$OUT/spotify_eval" "$model" | tee "$OUT/spotify-$model.txt" | grep -E "^passed" | sed "s|^|$model spotify: |" | tee -a "$SUMMARY"
    echo "==> $model: real transcripts"
    "$OUT/cleanup_eval" --real "$REAL" --out "$OUT" "$model" | grep -E "\| real " | sed "s|^|real cleanup: |" | tee -a "$SUMMARY"
    if [ -f "$LABELS" ]; then
        echo "==> $model: your Spotify labels"
        "$OUT/spotify_eval" --real "$LABELS" "$model" | tee "$OUT/spotify-real-$model.txt" | grep -E "^passed" | sed "s|^|$model real spotify: |" | tee -a "$SUMMARY"
    fi
done
ollama ps | awk 'NR>1 {print $1}' | xargs -r -n1 ollama stop 2>/dev/null || true

echo
echo "=== SUMMARY ($SUMMARY) ==="
cat "$SUMMARY"
echo "Per-sentence details: $OUT/cleanup-<model>.txt and $OUT/spotify-<model>.txt"
echo
python3 Tools/real_side_by_side.py "$OUT" > "$OUT/real-side-by-side.txt" && head -12 "$OUT/real-side-by-side.txt"
echo "Real transcripts side by side: $OUT/real-side-by-side.txt (.tsv for a spreadsheet)"
