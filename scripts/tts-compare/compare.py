#!/usr/bin/env python3
"""Compare Jarvis's TTS models by ear: reads fixed Turkish test sentences aloud, no mic needed.

For each engine it uses the running local server (or starts it from the app's install in
~/Library/Application Support/OpenWhisper), times every sentence, saves the WAVs and plays
them with `afplay`. Same HTTP protocol for all servers:
  GET /health -> {"ready": bool}   POST /speak {"text", "language"} -> audio/wav

  python3 scripts/tts-compare/compare.py                    # all installed engines
  python3 scripts/tts-compare/compare.py omnivoice --no-play
  python3 scripts/tts-compare/compare.py --interleave       # sentence 1 on every engine, then 2…

Output: scripts/tts-compare/out/<engine>/<n>.wav and a timing table (ms to audio, RTF).
Sentences are already in spoken form (numbers spelled out): the servers read digits badly,
and the app spells them before sending. Keep in step with `JarvisVoice.testSentences`.
"""

import argparse
import io
import json
import subprocess
import sys
import time
import urllib.request
import wave
from pathlib import Path

SUPPORT = Path.home() / "Library/Application Support/OpenWhisper"
HERE = Path(__file__).resolve().parent

ENGINES = {
    "omnivoice": {"port": 8767, "dir": SUPPORT / "tts"},
    "ema": {"port": 8770, "dir": SUPPORT / "tts-ema"},
    "antalia": {"port": 8771, "dir": SUPPORT / "tts-antalia"},
    "pocket": {"port": 8772, "dir": SUPPORT / "tts-pocket"},
}

SENTENCES = [
    "Tamamdır, efendim.",
    "Saat on dört sıfır beş, patron. Bugün üç toplantınız var.",
    "Yarın sabah dokuzda Ayşe Hanım'la görüşmeyi hatırlatayım mı?",
    "Spotify'da Tarkan çalıyorum, sesi biraz açtım.",
    "Ağaçların gölgesinde ılık bir rüzgâr eserken, şoför çocuğu güvenle okula bıraktı ve ışıklar yanınca geri döndü.",
    "Üzgünüm, bunu anlayamadım. Bir kez daha söyler misiniz?",
]


def get_json(url: str, timeout: float = 2.0):
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.loads(response.read() or b"{}")


def health(port: int):
    try:
        return get_json(f"http://127.0.0.1:{port}/health")
    except Exception:  # noqa: BLE001 - not running
        return None


def ensure_server(name: str, engine: dict, load_timeout: float):
    """Returns the server process we started (to stop later), None if one was already up."""
    port = engine["port"]
    state = health(port)
    started = None
    if state is None:
        python = engine["dir"] / ".venv/bin/python"
        script = engine["dir"] / "server.py"
        if not python.exists() or not script.exists():
            raise RuntimeError(f"not installed ({engine['dir']})")
        log = open(engine["dir"] / "compare.log", "ab")
        started = subprocess.Popen([str(python), str(script), "--port", str(port)],
                                   cwd=engine["dir"], stdout=log, stderr=subprocess.STDOUT)
        print(f"  [{name}] starting server on :{port} …")
    deadline = time.time() + load_timeout
    while time.time() < deadline:
        state = health(port)
        if state and state.get("ready"):
            return started
        if state and state.get("error"):
            raise RuntimeError(f"load failed: {state['error']}")
        if started and started.poll() is not None:
            raise RuntimeError(f"server exited, see {engine['dir'] / 'compare.log'}")
        time.sleep(1)
    raise RuntimeError(f"not ready after {load_timeout:.0f}s")


def speak(port: int, text: str) -> tuple[bytes, float, float]:
    """Returns (wav, ms to audio, audio seconds)."""
    body = json.dumps({"text": text, "language": "tr"}).encode()
    request = urllib.request.Request(f"http://127.0.0.1:{port}/speak", data=body,
                                     headers={"Content-Type": "application/json"})
    started = time.time()
    with urllib.request.urlopen(request, timeout=120) as response:
        data = response.read()
    elapsed = (time.time() - started) * 1000
    with wave.open(io.BytesIO(data)) as clip:
        seconds = clip.getnframes() / clip.getframerate()
    return data, elapsed, seconds


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("engines", nargs="*",
                        help=f"default: all installed ({', '.join(ENGINES)})")
    parser.add_argument("--no-play", action="store_true", help="only save and time, don't play")
    parser.add_argument("--interleave", action="store_true",
                        help="play sentence 1 on every engine, then sentence 2… (easier A/B)")
    parser.add_argument("--sentence", type=int, action="append",
                        help="only these sentence numbers (1-based), repeatable")
    parser.add_argument("--text", action="append", help="your own sentence(s) instead of the fixed set")
    parser.add_argument("--load-timeout", type=float, default=180)
    args = parser.parse_args()

    unknown = [n for n in args.engines if n not in ENGINES]
    if unknown:
        parser.error(f"unknown engine(s): {', '.join(unknown)} (choose from {', '.join(ENGINES)})")
    sentences = args.text or SENTENCES
    picked = [(i, s) for i, s in enumerate(sentences, 1) if not args.sentence or i in args.sentence]
    names = args.engines or [n for n, e in ENGINES.items()
                             if health(e["port"]) or (e["dir"] / ".venv/bin/python").exists()]
    if not names:
        print("No TTS engine installed.")
        return 1

    ready, ours = [], []
    for name in names:
        try:
            process = ensure_server(name, ENGINES[name], args.load_timeout)
            ready.append(name)
            if process:
                ours.append(process)
            print(f"  [{name}] ready")
        except RuntimeError as error:
            print(f"  [{name}] skipped: {error}")

    rows = []  # (engine, n, ms, seconds)
    clips = {}
    try:
        for name in ready:
            out = HERE / "out" / name
            out.mkdir(parents=True, exist_ok=True)
            for n, text in picked:
                try:
                    data, ms, seconds = speak(ENGINES[name]["port"], text)
                except Exception as error:  # noqa: BLE001 - report and go on
                    print(f"  [{name}] {n}: failed: {error}")
                    continue
                path = out / f"{n}.wav"
                path.write_bytes(data)
                clips[(name, n)] = path
                rows.append((name, n, ms, seconds))
                print(f"  [{name}] {n}: {ms:6.0f} ms for {seconds:4.1f} s audio (RTF {ms / 1000 / seconds:.2f})")
                if not args.no_play and not args.interleave:
                    print(f"     ▶ {text}")
                    subprocess.run(["afplay", str(path)])

        if not args.no_play and args.interleave:
            for n, text in picked:
                print(f"\n{n}. {text}")
                for name in ready:
                    if (name, n) in clips:
                        print(f"   ▶ {name}")
                        subprocess.run(["afplay", str(clips[(name, n)])])
                        time.sleep(0.4)
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        for process in ours:
            process.terminate()

    if rows:
        print(f"\n{'engine':<10} {'avg ms':>8} {'first ms':>9} {'avg RTF':>8}")
        for name in ready:
            mine = [r for r in rows if r[0] == name]
            if mine:
                avg = sum(r[2] for r in mine) / len(mine)
                rtf = sum(r[2] / 1000 / r[3] for r in mine) / len(mine)
                print(f"{name:<10} {avg:8.0f} {mine[0][2]:9.0f} {rtf:8.2f}")
        print(f"\nWAVs: {HERE / 'out'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
