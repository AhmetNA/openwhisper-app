"""Offline Supertonic 3 Turkish voice on Core ML (int4, Neural Engine).
LocalModelServer /health and /speak protocol. Model files are installed beside this file
by setup.sh; runtime never resolves a Hub model.

The int4 vector estimator has a fixed latent length of 128 (~8.9 s of audio), so a reply is
read sentence by sentence and a sentence that is still too long is split at commas or words.
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
from unicodedata import normalize

import numpy as np

MAX_CHARS = 2000
MAX_BODY = 16384
LANG = "tr"
VOICE = "M1"
STEPS = 8
SPEED = 1.05
TEXT_T = 128          # text encoder / duration predictor input length
LATENT_L = 128        # int4 vector estimator latent length
PIECE_CHARS = 110     # leaves room for the <tr></tr> tags inside TEXT_T
GAP_SECONDS = 0.12    # silence between pieces
MODEL_DIR = Path(__file__).resolve().parent / "model"

state = {"ready": False, "error": None, "parent_pid": None}
synth_lock = threading.Lock()

_CHAR_REPL = {"–": "-", "‑": "-", "—": "-", "_": " ", "“": '"', "”": '"',
              "‘": "'", "’": "'", "´": "'", "`": "'", "[": " ", "]": " ", "|": " ",
              "/": " ", "#": " ", "→": " ", "←": " "}
_EMOJI_RE = re.compile("[\U0001f300-\U0001faff☀-➿\U0001f1e6-\U0001f1ff]+")


def log(message: str) -> None:
    print(f"[supertonic] {message}", flush=True)


def load() -> None:
    try:
        import coremltools as ct
        started = time.monotonic()
        cfg = json.loads((MODEL_DIR / "tts.json").read_text())
        state["sample_rate"] = int(cfg["ae"]["sample_rate"])
        state["chunk"] = int(cfg["ae"]["base_chunk_size"]) * int(cfg["ttl"]["chunk_compress_factor"])
        state["latent_dim"] = int(cfg["ttl"]["latent_dim"]) * int(cfg["ttl"]["chunk_compress_factor"])
        state["indexer"] = json.loads((MODEL_DIR / "unicode_indexer.json").read_text())
        style = json.loads((MODEL_DIR / "voice_styles" / f"{VOICE}.json").read_text())
        for key in ("style_ttl", "style_dp"):
            dims = style[key]["dims"]
            state[key] = np.array(style[key]["data"], dtype=np.float32).reshape(1, dims[1], dims[2])
        units = ct.ComputeUnit.CPU_AND_NE
        for key, name in (("dp", "DurationPredictor_v2"), ("te", "TextEncoder_v2"),
                          ("ve", "VectorEstimatorVariants/VectorEstimator_v2_L128_int4"), ("vc", "Vocoder")):
            state[key] = ct.models.MLModel(str(MODEL_DIR / f"{name}.mlpackage"), compute_units=units)
        synthesize("Hazırım.")
        state["ready"] = True
        log(f"ready in {time.monotonic() - started:.2f}s")
    except Exception as error:
        state["error"] = f"Model load failed ({type(error).__name__}: {error}); rerun setup.sh"
        log(state["error"])


def clean(text: str) -> str:
    text = normalize("NFKD", text)
    text = _EMOJI_RE.sub("", text)
    for old, new in _CHAR_REPL.items():
        text = text.replace(old, new)
    return re.sub(r"\s+", " ", text).strip()


def tokens(text: str) -> tuple[np.ndarray, np.ndarray]:
    if not re.search(r"[.!?;:,'\")\]}…]$", text):
        text += "."
    codepoints = [ord(c) for c in f"<{LANG}>{text}</{LANG}>"][:TEXT_T]
    ids = np.zeros((1, TEXT_T), dtype=np.int32)
    mask = np.zeros((1, 1, TEXT_T), dtype=np.float32)
    indexer = state["indexer"]
    for i, cp in enumerate(codepoints):
        ids[0, i] = indexer[cp] if cp < len(indexer) and indexer[cp] >= 0 else 0
    mask[0, 0, :len(codepoints)] = 1.0
    return ids, mask


def duration(ids: np.ndarray, mask: np.ndarray) -> float:
    out = state["dp"].predict({"text_ids": ids, "style_dp": state["style_dp"], "text_mask": mask})
    return float(np.asarray(out["duration"], dtype=np.float32).reshape(-1)[0]) / SPEED


def max_seconds() -> float:
    return LATENT_L * state["chunk"] / state["sample_rate"]


def split_long(text: str) -> list[str]:
    """Halves text at the comma or space nearest its middle until each piece fits."""
    if len(text) <= PIECE_CHARS and duration(*tokens(text)) <= max_seconds() - 0.3:
        return [text]
    cuts = [m.end() for m in re.finditer(r",\s", text)] or [m.start() for m in re.finditer(r"\s", text)]
    if not cuts:
        return [text]  # one very long word: read what fits
    middle = len(text) / 2
    cut = min(cuts, key=lambda c: abs(c - middle))
    left, right = text[:cut].strip(), text[cut:].strip()
    if not left or not right:
        return [text]
    return split_long(left) + split_long(right)


def pieces(text: str) -> list[str]:
    sentences = [s.strip() for s in re.split(r"(?<=[.!?…])\s+", clean(text)) if s.strip()]
    return [p for s in sentences for p in split_long(s)]


def speak_piece(text: str, rng: np.random.Generator) -> np.ndarray:
    ids, mask = tokens(text)
    seconds = min(duration(ids, mask), max_seconds())
    emb = np.asarray(state["te"].predict({"text_ids": ids, "style_ttl": state["style_ttl"],
                                          "text_mask": mask})["text_emb"], dtype=np.float32)
    used = max(1, min(LATENT_L, -(-int(seconds * state["sample_rate"]) // state["chunk"])))
    latent_mask = np.zeros((1, 1, LATENT_L), dtype=np.float32)
    latent_mask[0, 0, :used] = 1.0
    xt = rng.standard_normal((1, state["latent_dim"], LATENT_L)).astype(np.float32) * latent_mask
    total = np.array([float(STEPS)], dtype=np.float32)
    for step in range(STEPS):
        xt = np.asarray(state["ve"].predict({
            "noisy_latent": xt, "text_emb": emb, "style_ttl": state["style_ttl"],
            "latent_mask": latent_mask, "text_mask": mask,
            "current_step": np.array([float(step)], dtype=np.float32), "total_step": total,
        })["denoised_latent"], dtype=np.float32)
    wav = np.asarray(state["vc"].predict({"latent": xt})["wav"], dtype=np.float32).reshape(-1)
    return wav[:min(used * state["chunk"], int(seconds * state["sample_rate"]))]


def synthesize(text: str) -> bytes:
    with synth_lock:
        # Fixed seed: the same reply always sounds the same, so prefetched acks match.
        rng = np.random.default_rng(42)
        gap = np.zeros(int(GAP_SECONDS * state["sample_rate"]), dtype=np.float32)
        parts = []
        for piece in pieces(text):
            if parts:
                parts.append(gap)
            parts.append(speak_piece(piece, rng))
    audio = np.concatenate(parts) if parts else gap
    pcm = (np.clip(audio, -1.0, 1.0) * 32767).astype("<i2").tobytes()
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(state["sample_rate"])
        out.writeframes(pcm)
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
            log(f"synthesis failed: {type(error).__name__}: {error}")
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
    parser.add_argument("--port", type=int, default=8777)
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
