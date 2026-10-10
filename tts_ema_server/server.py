"""Jarvis's experimental local voice: EMA Lightning (PyTorch, CPU) behind a tiny HTTP server.

Same protocol as `tts_server/server.py`, so the app talks to both the same way
(`LocalEMALightningProvider.swift`):
  GET  /health  -> {"ready": bool, "error": str|null}   answers at once, also while loading
  POST /speak   {"text": "..."} -> audio/wav (16-bit mono, 24 kHz)

EMA Lightning has one fixed Turkish voice (no cloning). `.lightning()` only speeds up CUDA,
and `EMA()` never picks Apple's GPU on its own, so this runs on the CPU. A fixed seed keeps a
phrase sounding the same every time it is made.

The server exits on its own when the app that started it is gone (`--parent-pid`).
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

import numpy as np

SAMPLE_RATE = 24000
SEED = 7
SPEED = 1.0
MAX_CHARS = 400

state = {"model": None, "ready": False, "error": None, "parent_pid": None}
synth_lock = threading.Lock()


def log(message: str) -> None:
    print(f"[ema] {message}", flush=True)


def load() -> None:
    try:
        started = time.time()
        from ema_lightning import EMA

        state["model"] = EMA(device="cpu")
        synthesize("Hazırım.")  # first generation warms up the kernels; keep it off a real reply
        state["ready"] = True
        log(f"ready in {time.time() - started:.1f}s")
    except Exception as error:  # noqa: BLE001 - reported through /health and the log
        state["error"] = f"{type(error).__name__}: {error}"
        log(f"load failed: {state['error']}")


def synthesize(text: str) -> bytes:
    with synth_lock:
        speech = state["model"].say(text, speed=SPEED, seed=SEED, sample_rate=SAMPLE_RATE)
    audio = np.asarray(speech.audio, dtype=np.float32).reshape(-1)
    pcm = (np.clip(audio, -1.0, 1.0) * 32767).astype("<i2").tobytes()
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(speech.sample_rate)
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
    parser.add_argument("--port", type=int, default=8770)
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
