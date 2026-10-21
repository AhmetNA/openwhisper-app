"""Installed-model smoke test: HTTP validation, WAV, latency and process cleanup."""
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import wave

installed = Path.home() / 'Library/Application Support/OpenWhisper/tts-phonon'
with socket.socket() as s:
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
with tempfile.TemporaryFile() as logs:
    process = subprocess.Popen([str(installed / '.venv/bin/python'), str(installed / 'server.py'),
                                '--port', str(port), '--parent-pid', str(os.getpid())],
                               stdout=logs, stderr=logs,
                               env={**os.environ, 'HF_HUB_OFFLINE': '1'})
    base = f'http://127.0.0.1:{port}'
    try:
        for _ in range(100):
            try:
                with urllib.request.urlopen(base + '/health', timeout=1) as response:
                    health = json.load(response)
                if health['error']:
                    raise RuntimeError(health['error'])
                if health['ready']:
                    assert health['pid'] == process.pid
                    break
            except urllib.error.URLError:
                pass
            time.sleep(0.1)
        else:
            raise RuntimeError('health timeout')
        for body, expected in [([], 400), ({'text': 4}, 400), ({'text': ' '}, 400),
                               ({'text': 'x' * 2001}, 413)]:
            request = urllib.request.Request(base + '/speak', data=json.dumps(body).encode(),
                                             headers={'Content-Type': 'application/json'})
            try:
                urllib.request.urlopen(request, timeout=10)
                raise AssertionError('invalid input accepted')
            except urllib.error.HTTPError as error:
                assert error.code == expected, (error.code, expected)
        started = time.monotonic()
        request = urllib.request.Request(base + '/speak',
            data=json.dumps({'text': 'Hello Ahmet. Your local assistant is ready. The meeting starts at two thirty.'}).encode(),
            headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=30) as response:
            assert response.headers['Content-Type'] == 'audio/wav'
            data = response.read()
        elapsed = time.monotonic() - started
        with wave.open(io.BytesIO(data)) as wav:
            assert wav.getnchannels() == 1 and wav.getsampwidth() == 2
            assert wav.getframerate() == 24000 and wav.getnframes() > 0
            duration = wav.getnframes() / wav.getframerate()
        Path('/tmp/jarvis-phonon-sample.wav').write_bytes(data)
        print(f'PASS: offline local model, HTTP validation, WAV; {duration:.2f}s audio in {elapsed:.3f}s')
    finally:
        process.terminate()
        process.wait(timeout=5)
