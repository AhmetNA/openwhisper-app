"""Synthetic text regression set + warmed wrapper latency, not an ASR quality benchmark.

Run with the installed Damga venv: python evaluate.py --out results.json
"""
import argparse
import json
import platform
import resource
import statistics
import subprocess
import time
from pathlib import Path

from server import DictationNormalizer

# Made-up identifiers only. Expected output is independent of the grammar implementation.
CASES = [
    ("money", "yüz elli lira", "150 TL"),
    ("money", "iki yüz elli lira elli kuruş", "250,50 TL"),
    ("money", "99 lira", "99 TL"),
    ("date", "on beş ekim iki bin yirmi altı", "15 Ekim 2026"),
    ("time", "saat dokuz otuz", "saat 09:30"),
    ("percent", "yüzde on iki virgül beş", "%12,5"),
    ("cardinal", "yirmi beş kişi geldi", "25 kişi geldi"),
    ("decimal", "bir nokta dokuz", "1,9"),
    ("phone", "telefonum sıfır beş otuz iki yüz yirmi üç kırk beş altmış yedi", "telefonum 0532 123 45 67"),
    ("email", "derya nokta öztürk et gmail nokta com", "derya.ozturk@gmail.com"),
    ("address", "numara on iki daire yedi", "No: 12 Daire: 7"),
    ("iban", "te re doksan altı sıfır sıfır sıfır altı iki sıfır sıfır sıfır sıfır sıfır sıfır sıfır sıfır sıfır sıfır sıfır bir iki üç dört beş altı", "TR96 0006 2000 0000 0000 1234 56"),
    ("plain", "Bir şey soracağım, bugün nasılsın?", "Bir şey soracağım, bugün nasılsın?"),
    ("plain", "Ben de onu dün gördüm.", "Ben de onu dün gördüm."),
    ("plain", "sesim kısık ondan olabilir", "sesim kısık ondan olabilir"),
    ("plain", "Bugün İrem ile görüştüm.", "Bugün İrem ile görüştüm."),
    ("plain", "Bir çay alabilir miyim?", "Bir çay alabilir miyim?"),
    ("code", "API UserDefaults userId GPT-4o ile yirmi beş kişi.", "API UserDefaults userId GPT-4o ile 25 kişi."),
    ("code", "kod `print(25)` ve yüz elli lira", "kod `print(25)` ve 150 TL"),
    ("code", "```swift\nlet count = 25\n```", "```swift\nlet count = 25\n```"),
    ("code", "src/main.swift ve user_name", "src/main.swift ve user_name"),
    ("url", "URL https://example.com/API?x=1 ve yüz elli lira", "URL https://example.com/API?x=1 ve 150 TL"),
    ("email", "ahmet@example.com ve yüz elli lira", "ahmet@example.com ve 150 TL"),
    ("written", "2026 seçimleri 1500 kişi 25.600 TL", "2026 seçimleri 1500 kişi 25.600 TL"),
    ("written", "IBAN TR96 0006 2000 0000 0000 1234 56", "IBAN TR96 0006 2000 0000 0000 1234 56"),
    ("written", "Saat 09:30'da buluşalım.", "Saat 09:30'da buluşalım."),
    ("layout", "satır bir\nsatır iki\tson", "satır bir\nsatır iki\tson"),
    ("glossary", "a ve es ile yüz elli lira", "a ve es ile 150 TL"),
    ("glossary", "PostgreSQL ve ChatGPT kullanıyorum.", "PostgreSQL ve ChatGPT kullanıyorum."),
    ("empty", "", ""),
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path)
    parser.add_argument("--iterations", type=int, default=100)
    args = parser.parse_args()
    started = time.perf_counter()
    normalizer = DictationNormalizer()
    initialization_ms = (time.perf_counter() - started) * 1000
    terms = ["a ve es", "PostgreSQL", "ChatGPT"]
    failures = []
    latencies = []
    for category, source, expected in CASES:
        result = normalizer.normalize(source, terms)
        if result != expected:
            failures.append({"category": category, "input": source, "expected": expected, "actual": result})
        if normalizer.normalize(result, terms) != result:
            failures.append({"category": "idempotence", "input": source})
    long_input = "yüz elli lira " * 400
    assert normalizer.normalize(long_input) == long_input, "over-limit input must stay intact"
    # Warm wrapper timing includes masking and restoration, but excludes HTTP/Swift overhead.
    for _ in range(args.iterations):
        for _, source, _ in CASES:
            start = time.perf_counter()
            normalizer.normalize(source, terms)
            latencies.append((time.perf_counter() - start) * 1000)
    latencies.sort()
    cpu = subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip()
    current_kib = int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(__import__('os').getpid())], text=True))
    report = {"platform": platform.platform(), "machine": platform.machine(), "cpu": cpu,
              "python": platform.python_version(), "damga": "1.0.3", "backend": "native",
              "cases": len(CASES), "failures": failures, "initialization_ms": initialization_ms,
              "p50_ms": statistics.median(latencies), "p95_ms": latencies[int(len(latencies) * .95)],
              "samples": len(latencies), "rss_mib": current_kib / 1024,
              "peak_rss_mib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024**2,
              "scope": "synthetic text -> protected ITN wrapper; no audio, no Swift/HTTP timing"}
    print(json.dumps(report, indent=2, ensure_ascii=False))
    if args.out:
        args.out.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
