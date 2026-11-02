# Ahenk Cep for Jarvis

Run `bash servers/tts_ahenk_server/setup.sh` from app/, then select
**Yerel — Ahenk Cep (Türkçe)** in Settings > Sesli cevap.
The global default remains Pocket. Ahenk uses an isolated Python 3.12 environment
at `~/Library/Application Support/OpenWhisper/tts-ahenk`, port 8776,
CPU with two threads, 16 steps, CFG 2, seed 0, speed 1, neutral style.
The installed weights and inference module are pinned; runtime does not download files.
Output: 48 kHz mono 16-bit WAV. It has one synthetic female Turkish voice, no cloning.
See NOTICE.md for attribution.

## Local verification — 2026-11-01

`python3 scripts/tts-compare/compare.py ahenk ema pocket --no-play`
with three custom short replies (Tamamdır, patron.; Saat 14.30 için hatırlatıcını
oluşturdum.; Spotify üzerinden müziği açıyorum.):

| Engine | Warm synthesis, ms | Mean, ms |
|---|---|---|
| Ahenk Cep | 77 / 123 / 90 | 97 |
| EMA | 50 / 94 / 61 | 68 |
| Pocket | 275 / 330 / 238 | 281 |

Separate fresh-process Ahenk check: 1.5 s load/warm-up, peak RSS 318.9 MiB,
134 / 177 / 96 ms synthesis. These small samples are not a general benchmark;
load state and concurrent work affect timings. WAV headers validated.
Audio quality and real microphone-driven interaction have not been evaluated.
