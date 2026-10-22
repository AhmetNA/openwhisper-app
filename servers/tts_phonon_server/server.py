"""Offline Phonon 31m English voice. LocalModelServer /health and /speak protocol.
Model files are installed beside this file; runtime never resolves a Hub model.
"""
import argparse
import io
import json
import os
import re
import sys
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np

MAX_CHARS = 2000
MAX_BODY = 16384
state = {"tts": None, "ready": False, "error": None, "parent_pid": None}
synth_lock = threading.Lock()


def log(message: str) -> None:
    print(f"[phonon] {message}", flush=True)


def load() -> None:
    try:
        import ptts
        started = time.monotonic()
        ptts.set_num_threads(2)
        state["tts"] = ptts.TTS(str(Path(__file__).resolve().parent / "model"),
                                lang="en", device="cpu", quant="q8", voice="default")
        synthesize("Ready.")
        state["ready"] = True
        log(f"ready in {time.monotonic() - started:.2f}s")
    except Exception as error:
        state["error"] = f"Model load failed ({type(error).__name__}); rerun setup.sh"
        log(state["error"])


def delivery(text: str) -> tuple[str, float]:
    """Conservative English prosody cues, not an emotion classifier.

    Never rewrite the reply. Identical text always selects the same delivery,
    including cache prefetch. Negative/uncertain cues override enthusiasm.
    """
    lower = text.lower().replace("’", "'")
    if re.search(r"\b(sorry|unfortunately|sad|worried|afraid|cannot|can't|couldn't|failed|error|warning|danger|emergency|not|never)\b", lower):
        return "calm", 0.15
    if "..." in text or "…" in text:
        return "hesitant", 0.3
    # Keep ordinary questions and factual answers at the default pace.
    if "?" in text:
        return "question", 0.0
    if re.match(r"^(great|wonderful|fantastic|congratulations|excellent|hooray|good news)\b", lower):
        return "upbeat", -0.3
    if re.match(r"^(right away|on it|absolutely|of course|you're welcome)\b", lower):
        return "warm", -0.15
    return "normal", 0.0


def synthesize(text: str) -> bytes:
    tone, delta = delivery(text)
    with synth_lock:
        # Conditions are mutable model state: select and synthesize atomically.
        # Always reset, including normal replies, so one tone cannot leak to the next.
        state["tts"].set_conditions({"duration_delta": delta})
        audio = state["tts"].synth(text, voice="default", seed=42, temperature=0.3)
    log(f"delivery={tone}")
    pcm = (np.clip(audio, -1.0, 1.0) * 32767).astype("<i2").tobytes()
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(state["tts"].sample_rate)
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
            if not 0 < length <= MAX_BODY:
                self._json(413, {"error": "invalid body size"})
                return
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict) or not isinstance(body.get("text"), str):
                raise ValueError("invalid text")
            text = body["text"].strip()
            if len(text) > MAX_CHARS:
                self._json(413, {"error": "text too long"})
                return
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
            log(f"synthesis failed: {type(error).__name__}")
            self._json(500, {"error": "synthesis failed"})
            return
        log(f"synthesis {(time.time() - started) * 1000:.0f} ms")
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
    parser.add_argument("--port", type=int, default=8775)
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
