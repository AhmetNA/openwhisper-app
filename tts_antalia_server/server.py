"""Experimental: Antalia-1 (PatientDesk, open weights) behind the same tiny HTTP server.

Only for comparing voices with `scripts/tts-compare/compare.py`; the app doesn't use it.
Same protocol as `tts_server/server.py`:
  GET  /health  -> {"ready": bool, "error": str|null}   answers at once, also while loading
  POST /speak   {"text": "..."} -> audio/wav (16-bit mono, 24 kHz)

Antalia-1 is one fixed Turkish (female) voice, ~305M params + BigVGAN v2 vocoder, CUDA-first;
here it runs on Apple's GPU (MPS) with a CPU fallback. Development of the model is
discontinued. Weights: Antalia OpenRAIL-M, credit "Antalia 1" by PatientDesk
(https://huggingface.co/cloud0day3/antalia-1). `setup.sh` puts the code and BigVGAN in place.
"""

import argparse
import io
import json
import os
import sys
import threading
import time
import wave
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE / "antalia" / "src"), str(HERE / "bigvgan")]
CHECKPOINT = "cloud0day3/antalia-1"
VOCODER = "nvidia/bigvgan_v2_24khz_100band_256x"
SPEAKER = "voicedata-candidate-b"
# Recipe from the model card. 16 steps: ~45% faster, same mean speaker similarity.
RECIPE = dict(
    prosody=[-1.2398956, 1.1943912, -2.1267404, -0.9549347, 0.9637866, 0.5145879],
    text_guidance_scale=4.0, sway_coefficient=-0.8, mel_clamp=5.0,
    min_seconds_per_char=0.085, chunk_character_limit=120,
)
STEPS = int(os.environ.get("ANTALIA_STEPS", "16"))
SEED = 20260803
MAX_CHARS = 400

state = {"parts": None, "device": None, "ready": False, "error": None, "parent_pid": None}
synth_lock = threading.Lock()


def log(message: str) -> None:
    print(f"[antalia] {message}", flush=True)


def load() -> None:
    try:
        started = time.time()
        import torch
        from turkish_tts import crossflow_train as cf

        device = os.environ.get("ANTALIA_DEVICE") or ("mps" if torch.backends.mps.is_available() else "cpu")
        model, tokenizer, payload = cf.load_crossflow_checkpoint(Path(CHECKPOINT), device)
        train_config = cf.CrossFlowTrainConfig(**payload["train_config"])
        state["parts"] = dict(
            model=model, tokenizer=tokenizer, train_config=train_config,
            speaker_id=cf._resolve_speaker_id(payload, SPEAKER),
            mel_normalizer=cf.MelNormalizer(train_config, device),
            vocoder=cf._load_crossflow_vocoder(Path(VOCODER), device),
        )
        state["device"] = device
        synthesize("Hazırım.")  # first generation warms up the kernels; keep it off a real reply
        state["ready"] = True
        log(f"ready on {device} in {time.time() - started:.1f}s ({STEPS} steps)")
    except Exception as error:  # noqa: BLE001 - reported through /health and the log
        state["error"] = f"{type(error).__name__}: {error}"
        log(f"load failed: {state['error']}")


def synthesize(text: str) -> bytes:
    from turkish_tts import crossflow_train as cf

    parts, device = state["parts"], state["device"]
    config = parts["train_config"]
    with synth_lock:
        waveform, _, _ = cf._synthesize_loaded_crossflow(
            model=parts["model"], tokenizer=parts["tokenizer"], vocoder=parts["vocoder"],
            mel_normalizer=parts["mel_normalizer"], text=text,
            sample_rate=config.sample_rate, hop_length=config.hop_length, device=device,
            steps=STEPS, seed=SEED, duration_scale=1.0, speaker_id=parts["speaker_id"],
            speaker_guidance_scale=1.0, solver="euler", guidance_rescale=0.0, reference=None,
            context_guidance_scale=1.0, chunk_pause_seconds=0.16, auto_style=None,
            mel_correction=None, text_normalization=config.text_normalization, **RECIPE,
        )
    audio = np.asarray(waveform, dtype=np.float32).reshape(-1)
    pcm = (np.clip(audio, -1.0, 1.0) * 32767).astype("<i2").tobytes()
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(config.sample_rate)
        wav.writeframes(pcm)
    return buffer.getvalue()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path != "/health":
            self.send_error(404)
            return
        # pid/parent_pid let the app tell its own server from a stray one (e.g. a manual test run).
        self._json(200, {"ready": state["ready"], "error": state["error"],
                         "pid": os.getpid(), "parent_pid": state["parent_pid"]})

    def do_POST(self) -> None:
        if self.path != "/speak":
            self.send_error(404)
            return
        if not state["ready"]:
            self._json(503, {"error": state["error"] or "loading"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length) or b"{}")
            text = str(body.get("text", "")).strip()[:MAX_CHARS]
        except (ValueError, json.JSONDecodeError):
            self._json(400, {"error": "bad request"})
            return
        if not text:
            self._json(400, {"error": "empty text"})
            return
        started = time.time()
        try:
            data = synthesize(text)
        except Exception as error:  # noqa: BLE001
            log(f"synthesis failed for {text!r}: {error}")
            self._json(500, {"error": str(error)})
            return
        log(f"{(time.time() - started) * 1000:.0f} ms  {text!r}")
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _json(self, status: int, payload: dict) -> None:
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args) -> None:  # silence per-request access logs
        pass


def exit_with_parent(parent_pid: int) -> None:
    while True:
        time.sleep(2)
        try:
            os.kill(parent_pid, 0)
        except ProcessLookupError:
            log("app is gone, exiting")
            os._exit(0)
        except PermissionError:
            pass


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8771)
    parser.add_argument("--parent-pid", type=int)
    args = parser.parse_args()

    try:
        server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    except OSError as error:
        log(f"cannot listen on 127.0.0.1:{args.port}: {error}")
        sys.exit(1)
    state["parent_pid"] = args.parent_pid
    if args.parent_pid:
        threading.Thread(target=exit_with_parent, args=(args.parent_pid,), daemon=True).start()
    threading.Thread(target=load, daemon=True).start()
    log(f"listening on 127.0.0.1:{args.port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
