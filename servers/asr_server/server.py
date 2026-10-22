"""Alternative speech-to-text: Qwen3-ASR 1.7B (MLX) behind a tiny HTTP server on 127.0.0.1.

The app (`LocalQwenASRProvider.swift`) starts this with the venv's python when "Qwen3-ASR" is
picked under Ayarlar › Konuşma modeli, and talks to it:
  GET  /health      -> {"ready": bool, "error": str?, "model": str}
  POST /transcribe  {"audio_pcm16_b64": "...", "language": "tr", "hotwords": ["Spotify", ...]}
                    -> {"text": "...", "ms": float, "seconds": float}

Audio is 16 kHz mono 16-bit PCM. `hotwords` (the user's glossary) is optional: Qwen3-ASR folds it
into its system prompt, which Whisper cannot do in this app. With it, clips under ~2 s of
"Teşekkürler." / "Yah." came back as the whole 445-word glossary (30 Sep 2026), so an answer with
more words than anyone can say in the clip is thrown away and the clip is transcribed again
without hotwords.

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

# 8-bit: same accuracy as bf16 in the soniqo benchmark, half the memory (~2.5 GB loaded).
MODEL_ID = os.environ.get("OPENWHISPER_ASR_MODEL", "mlx-community/Qwen3-ASR-1.7B-8bit")
LANGUAGES = {"tr": "Turkish", "en": "English", "de": "German", "fr": "French", "es": "Spanish"}
MAX_HOTWORDS = 500

state = {"model": None, "ready": False, "error": None}
# MLX runs one generation at a time; /health stays answerable meanwhile.
generate_lock = threading.Lock()


def log(message: str) -> None:
    print(f"[asr] {time.strftime('%H:%M:%S')} {message}", flush=True)


def load() -> None:
    try:
        started = time.time()
        from mlx_audio.stt.utils import load_model

        state["model"] = load_model(MODEL_ID)
        transcribe(np.zeros(16_000, dtype=np.float32), "tr", None)  # compiles kernels
        state["ready"] = True
        log(f"{MODEL_ID} ready in {time.time() - started:.1f}s")
    except Exception as error:  # noqa: BLE001 - reported through /health and the log
        state["error"] = f"{type(error).__name__}: {error}"
        log(f"load failed: {state['error']}")


def transcribe(audio: np.ndarray, language: str, hotwords: list[str] | None) -> str:
    with generate_lock:
        result = state["model"].generate(
            audio,
            language=LANGUAGES.get(language),  # None = auto-detect
            hotwords=hotwords or None,
        )
    return result.text.strip()


def max_plausible_words(seconds: float) -> int:
    # Fast Turkish speech is ~3 words/s; double it plus slack so real speech never trips it.
    return int(6 * seconds) + 8


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
            hotwords = [str(w) for w in (body.get("hotwords") or [])][:MAX_HOTWORDS]
        except (KeyError, ValueError, json.JSONDecodeError):
            self._json(400, {"error": "bad request"})
            return
        if audio.size < 1_600:  # under 0.1 s
            self._json(200, {"text": "", "ms": 0, "seconds": 0})
            return
        started = time.time()
        seconds = audio.size / 16_000
        try:
            text = transcribe(audio, language, hotwords)
            if hotwords and len(text.split()) > max_plausible_words(seconds):
                log(f"hotwords leaked into {seconds:.1f}s clip ({len(text.split())} words); retrying without them")
                text = transcribe(audio, language, None)
        except Exception as error:  # noqa: BLE001
            log(f"transcription failed: {error}")
            self._json(500, {"error": str(error)})
            return
        ms = (time.time() - started) * 1000
        log(f"{ms:.0f} ms for {seconds:.1f}s audio, hotwords={len(hotwords)}: {text!r}")
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
    parser.add_argument("--port", type=int, default=8769)
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
