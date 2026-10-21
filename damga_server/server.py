"""Optional final-dictation ITN; loopback only, native WFST, no network/model downloads."""
import argparse
import json
import os
import re
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_CHARS = 4000
SERVICE = "jarvis-damga-1.0.3"
# Written identifiers and code must survive verbatim. Spoken entities remain available to ITN.
PROTECTED = re.compile(
    r"```[\s\S]*?```|`[^`\n]+`|https?://[^\s<>]+|[\w.+-]+@[\w.-]+\.[\w-]+"
    r"|\bTR\d{2}(?:[ ]?\d){22}\b|(?:~/|/)[\w./-]+"
    r"|\b[\w.-]*[a-z][A-Z][\w.-]*\b|\b[A-Z][A-Z\d_+.-]+\b"
    r"|\b(?=[\w.+-]*[A-Za-z])(?=[\w.+-]*\d)[\w.+-]+\b|\b\w+_\w+\b|\r\n|[\n\r\t]"
)


class DictationNormalizer:
    def __init__(self):
        from damga import InverseNormalizer
        self.itn = InverseNormalizer(backend="native", repair_spelling=False, preserve_case=True)
        self.lock = threading.Lock()

    def normalize(self, text, protected_terms=()):
        if not text or len(text) > MAX_CHARS:
            return text
        # The native grammar also includes brands/spelling. Mask the user's glossary and
        # learned right-hand terms instead of letting those tables reinterpret them.
        terms = sorted({t for t in protected_terms if isinstance(t, str) and t}, key=len, reverse=True)
        patterns = [PROTECTED.pattern]
        if terms:
            patterns.insert(0, r"(?<!\w)(?:" + "|".join(re.escape(t) for t in terms) + r")(?!\w)")
        pattern = re.compile("|".join(patterns))
        prefix = "zjq" + uuid.uuid4().hex.translate(str.maketrans("0123456789", "abcdefghij"))
        saved = []

        def mask(match):
            # Alphabetic placeholders cannot be mistaken for number fragments.
            index = len(saved)
            suffix = ""
            while True:
                suffix += chr(97 + index % 26)
                index //= 26
                if not index:
                    break
            marker = prefix + suffix + "zjq"
            saved.append((marker, match.group()))
            return marker

        masked = pattern.sub(mask, text)
        with self.lock:
            output = self.itn.normalize(masked)
        if not output or any(output.count(marker) != 1 for marker, _ in saved):
            return text
        # Placeholder order is another guard against a destructive rewrite.
        positions = [output.index(marker) for marker, _ in saved]
        if positions != sorted(positions):
            return text
        for marker, original in saved:
            output = output.replace(marker, original)
        return output


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            self.send_error(404)
            return
        self.reply(200, {"ready": True, "service": SERVICE,
                         "pid": os.getpid(), "parent_pid": self.server.parent_pid})

    def do_POST(self):
        if self.path != "/normalize":
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 128_000:
                raise ValueError("size")
            body = json.loads(self.rfile.read(length))
            text = body["text"]
            terms = body.get("protected_terms", [])
            if not isinstance(text, str) or len(text) > MAX_CHARS:
                raise ValueError("text")
            if not isinstance(terms, list) or len(terms) > 1000 or any(not isinstance(t, str) for t in terms):
                raise ValueError("terms")
        except (ValueError, KeyError, TypeError):
            self.reply(400, {"error": "invalid request"})
            return
        started = time.perf_counter()
        try:
            result = self.server.normalizer.normalize(text, terms)
            self.reply(200, {"text": result, "ms": (time.perf_counter() - started) * 1000})
        except Exception:
            # No transcripts (including phones/IBANs) are written to the server log.
            self.reply(500, {"error": "normalization failed"})

    def reply(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass


def exit_with_parent(pid):
    while True:
        time.sleep(2)
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            os._exit(0)
        except PermissionError:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8774)
    parser.add_argument("--parent-pid", type=int, required=True)
    args = parser.parse_args()
    threading.Thread(target=exit_with_parent, args=(args.parent_pid,), daemon=True).start()
    normalizer = DictationNormalizer()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.normalizer = normalizer
    server.parent_pid = args.parent_pid
    server.serve_forever()


if __name__ == "__main__":
    main()
