"""Alternative speech-to-text: NVIDIA Nemotron 3.5 ASR 0.6B (PyTorch on MPS) behind a tiny HTTP
server on 127.0.0.1.

The app (`LocalNemotronASRProvider.swift`) starts this with the venv's python when "Nemotron 3.5
ASR" is picked under Ayarlar › Konuşma modeli, and talks to it:
  GET  /health      -> {"ready": bool, "error": str?, "model": str}
  POST /transcribe  {"audio_pcm16_b64": "...", "language": "tr"}
                    -> {"text": "...", "ms": float, "seconds": float}

Audio is 16 kHz mono 16-bit PCM. On the 48-clip Turkish corpus (tools/whisper-compare) it was
about twice as fast as Whisper Turbo but made twice as many errors (clean WER 17.1% vs 8.4%).

The server exits on its own when the app that started it is gone (`--parent-pid`), like the
voice and decision servers.
"""

import argparse
import base64
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

MODEL_ID = "nvidia/nemotron-3.5-asr-streaming-0.6b"
# The model takes a locale; "auto" lets it detect the language.
LOCALES = {"tr": "tr-TR", "en": "en-US", "de": "de-DE", "fr": "fr-FR", "es": "es-ES"}
SAMPLE_RATE = 16_000

state = {"model": None, "processor": None, "ready": False, "error": None}
# One transcription at a time on the GPU; /health stays answerable meanwhile.
generate_lock = threading.Lock()


def log(message: str) -> None:
    print(f"[nemotron] {time.strftime('%H:%M:%S')} {message}", flush=True)


def load() -> None:
    try:
        started = time.time()
        import torch
        from transformers import AutoModelForRNNT, AutoProcessor

        device = "mps" if torch.backends.mps.is_available() else "cpu"
        state["processor"] = AutoProcessor.from_pretrained(MODEL_ID)
        state["model"] = AutoModelForRNNT.from_pretrained(MODEL_ID).to(device).eval()
        transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32), "tr")  # warms up the kernels
        state["ready"] = True
        log(f"{MODEL_ID} ready on {device} in {time.time() - started:.1f}s")
    except Exception as error:  # noqa: BLE001 - reported through /health and the log
        state["error"] = f"{type(error).__name__}: {error}"
        log(f"load failed: {state['error']}")


def transcribe(audio: np.ndarray, language: str) -> str:
    import torch

    processor, model = state["processor"], state["model"]
    inputs = processor(audio, sampling_rate=SAMPLE_RATE, language=LOCALES.get(language, "auto"))
    inputs.to(model.device, dtype=model.dtype)
    with generate_lock, torch.inference_mode():
        output = model.generate(**inputs, return_dict_in_generate=True)
    text = processor.decode(output.sequences, skip_special_tokens=True)
    return (text[0] if isinstance(text, list) else text).strip()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path != "/health":
            self.send_error(404)
            return
        self._json(200, {"ready": state["ready"], "error": state["error"], "model": MODEL_ID})

    def do_POST(self) -> None:
        if self.path != "/transcribe":
            self.send_error(404)
            return
        if not state["ready"]:
            self._json(503, {"error": state["error"] or "loading"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length) or b"{}")
            pcm = base64.b64decode(body["audio_pcm16_b64"])
            audio = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0
            language = str(body.get("language") or "tr")
        except (KeyError, ValueError, json.JSONDecodeError):
            self._json(400, {"error": "bad request"})
            return
        if audio.size < 1_600:  # under 0.1 s
            self._json(200, {"text": "", "ms": 0, "seconds": 0})
            return
        started = time.time()
        seconds = audio.size / SAMPLE_RATE
        try:
            text = transcribe(audio, language)
        except Exception as error:  # noqa: BLE001
            log(f"transcription failed: {error}")
            self._json(500, {"error": str(error)})
            return
        ms = (time.time() - started) * 1000
        log(f"{ms:.0f} ms for {seconds:.1f}s audio: {text!r}")
        self._json(200, {"text": text, "ms": round(ms, 1), "seconds": round(seconds, 2)})

    def _json(self, status: int, payload: dict) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode()
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
    parser.add_argument("--port", type=int, default=8776)
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
