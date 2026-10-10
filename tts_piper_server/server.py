"""Jarvis's English voice: Piper's Jarvis model (ONNX, CPU) behind a tiny HTTP server.

Same protocol as `tts_server/server.py`, so the app talks to both the same way
(`LocalPiperJarvisProvider.swift`):
  GET  /health  -> {"ready": bool, "error": str|null}   answers at once, also while loading
  POST /speak   {"text": "..."} -> audio/wav (16-bit mono, 22.05 kHz)

jgkawell/jarvis (medium, ~63 MB) imitates the MCU J.A.R.V.I.S. and only speaks English; the app
translates Turkish replies before they get here. Piper's own pip package can't find its espeak
data on macOS, so the model runs directly on onnxruntime and phonemizer uses Homebrew's
espeak-ng (`brew install espeak-ng`). espeak reads digits itself ("2:05" -> "two oh five").

The server exits on its own when the app that started it is gone (`--parent-pid`).
"""

import argparse
import io
import json
import logging
import os
import sys
import threading
import time
import unicodedata
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np

REPO = "jgkawell/jarvis"
REVISION = "37f8763122312665f091d1fc760abaf1f79b02cc"
MODEL = "en/en_GB/jarvis/medium/jarvis-medium.onnx"
# The app starts us without a login shell, so point phonemizer at Homebrew's espeak-ng here.
ESPEAK_LIBRARY = "/opt/homebrew/lib/libespeak-ng.dylib"
MAX_CHARS = 400

state = {"session": None, "config": None, "phonemizer": None, "ready": False, "error": None, "parent_pid": None}
synth_lock = threading.Lock()


def log(message: str) -> None:
    print(f"[piper] {message}", flush=True)


def load() -> None:
    try:
        started = time.time()
        if not Path(ESPEAK_LIBRARY).exists():
            raise RuntimeError("espeak-ng is missing: brew install espeak-ng")
        os.environ.setdefault("PHONEMIZER_ESPEAK_LIBRARY", ESPEAK_LIBRARY)
        import onnxruntime
        from huggingface_hub import hf_hub_download
        from phonemizer.backend import EspeakBackend

        logging.getLogger("phonemizer").setLevel(logging.ERROR)  # "words count mismatch" on every call
        model_path = hf_hub_download(REPO, MODEL, revision=REVISION)
        config = json.loads(Path(hf_hub_download(REPO, MODEL + ".json", revision=REVISION)).read_text())
        state["session"] = onnxruntime.InferenceSession(model_path, providers=["CPUExecutionProvider"])
        state["config"] = config
        state["phonemizer"] = EspeakBackend(config["espeak"]["voice"], preserve_punctuation=True, with_stress=True)
        synthesize("Ready, sir.")  # first generation warms up onnxruntime; keep it off a real reply
        state["ready"] = True
        log(f"ready in {time.time() - started:.1f}s")
    except Exception as error:  # noqa: BLE001 - reported through /health and the log
        state["error"] = f"{type(error).__name__}: {error}"
        log(f"load failed: {state['error']}")


def synthesize(text: str) -> bytes:
    config = state["config"]
    ids_map, inference = config["phoneme_id_map"], config["inference"]
    with synth_lock:
        phonemes = state["phonemizer"].phonemize([text], strip=True)[0]
        # Piper's input: start, then every phoneme followed by the pad, then end.
        ids = ids_map["^"] + ids_map["_"]
        for ch in unicodedata.normalize("NFD", phonemes):
            if ch in ids_map:
                ids += ids_map[ch] + ids_map["_"]
        ids += ids_map["$"]
        x = np.array([ids], dtype=np.int64)
        audio = state["session"].run(None, {
            "input": x,
            "input_lengths": np.array([x.shape[1]], dtype=np.int64),
            "scales": np.array([inference["noise_scale"], inference["length_scale"], inference["noise_w"]], dtype=np.float32),
        })[0].reshape(-1)
    pcm = (np.clip(audio, -1.0, 1.0) * 32767).astype("<i2").tobytes()
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(config["audio"]["sample_rate"])
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
    parser.add_argument("--port", type=int, default=8773)
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
