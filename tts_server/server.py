"""Jarvis's local voice: OmniVoice (MLX) behind a tiny HTTP server on 127.0.0.1.

The app (`JarvisVoice.swift`) starts this with the venv's python and talks to it:
  GET  /health  -> {"ready": bool}          answers at once, also while the model loads
  POST /speak   {"text": "...", "language": "tr"} -> audio/wav (16-bit mono, 24 kHz)

Every reply is cloned from one fixed reference clip (`jarvis_ref.wav`, spoken in Turkish),
so the voice never drifts between replies. A British/English reference was tried and made
short Turkish replies unintelligible. Digits must be spelled out by the caller: OmniVoice
reads "14:05" badly.

The server exits on its own when the app that started it is gone (`--parent-pid`), because a
force-killed app (build.sh does `pkill -9`) never gets to stop it.
"""

import argparse
import io
import json
import os
import sys
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np

MODEL_ID = "mlx-community/OmniVoice-bf16"
HERE = Path(__file__).resolve().parent
REF_AUDIO = HERE / "jarvis_ref.wav"
# Must match what `jarvis_ref.wav` says word for word, or cloning produces garbage.
REF_TEXT = "İyi akşamlar efendim. Tüm sistemler çevrimiçi ve tam kapasiteyle çalışıyor."
# 32 diffusion steps: 16 or fewer is 2x faster but mispronounces short Turkish replies.
NUM_STEPS = 32
MAX_CHARS = 400

state = {"model": None, "ref_tokens": None, "ready": False, "error": None}
# MLX runs one generation at a time; /health stays answerable meanwhile.
synth_lock = threading.Lock()


def log(message: str) -> None:
    print(f"[tts] {message}", flush=True)


def load() -> None:
    try:
        started = time.time()
        from mlx_audio.tts.utils import load_model
        from mlx_audio.tts.models.omnivoice.utils import create_voice_clone_prompt

        model = load_model(MODEL_ID)
        ref_tokens = create_voice_clone_prompt(
            str(REF_AUDIO), tokenizer=model.audio_tokenizer, max_duration_s=10.0
        )
        state["model"], state["ref_tokens"] = model, ref_tokens
        synthesize("Hazırım.", "tr")  # first generation compiles kernels; keep it off a real reply
        state["ready"] = True
        log(f"ready in {time.time() - started:.1f}s")
    except Exception as error:  # noqa: BLE001 - reported through /health and the log
        state["error"] = f"{type(error).__name__}: {error}"
        log(f"load failed: {state['error']}")


def synthesize(text: str, language: str) -> bytes:
    with synth_lock:
        result = next(
            state["model"].generate(
                text=text,
                language=language,
                ref_tokens=state["ref_tokens"],
                ref_text=REF_TEXT,
                num_steps=NUM_STEPS,
            )
        )
        audio = np.array(result.audio, dtype=np.float32).reshape(-1)
        sample_rate = result.sample_rate
    pcm = (np.clip(audio, -1.0, 1.0) * 32767).astype("<i2").tobytes()
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(pcm)
    return buffer.getvalue()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path != "/health":
            self.send_error(404)
            return
        self._json(200, {"ready": state["ready"], "error": state["error"]})

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
            language = str(body.get("language") or "tr")
        except (ValueError, json.JSONDecodeError):
            self._json(400, {"error": "bad request"})
            return
        if not text:
            self._json(400, {"error": "empty text"})
            return
        started = time.time()
        try:
            data = synthesize(text, language)
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
    parser.add_argument("--port", type=int, default=8767)
    parser.add_argument("--parent-pid", type=int)
    args = parser.parse_args()

    try:
        server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    except OSError as error:
        log(f"cannot listen on 127.0.0.1:{args.port}: {error}")
        sys.exit(1)
    if args.parent_pid:
        threading.Thread(target=exit_with_parent, args=(args.parent_pid,), daemon=True).start()
    threading.Thread(target=load, daemon=True).start()
    log(f"listening on 127.0.0.1:{args.port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
