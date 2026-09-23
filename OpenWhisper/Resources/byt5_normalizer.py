#!/usr/bin/env python3
"""Line-delimited JSON bridge for erdemKocaogluu/byt5-small-tr-normalizer."""

import argparse
import json
import re
import sys

MODEL_ID = "erdemKocaogluu/byt5-small-tr-normalizer"
MAX_INPUT_BYTES = 320


def load_runtime():
    import torch
    from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
    model = AutoModelForSeq2SeqLM.from_pretrained(MODEL_ID)
    model.to("cpu").eval()
    torch.set_num_threads(max(1, min(8, torch.get_num_threads())))
    return torch, tokenizer, model


def chunks(text):
    """Preserve paragraphs and keep ByT5 byte sequences bounded at whitespace."""
    pieces = re.split(r"(\n+)", text)
    for piece in pieces:
        if not piece or piece.startswith("\n"):
            yield piece
            continue
        words = re.findall(r"\S+\s*", piece)
        current = ""
        for word in words:
            if current and len((current + word).encode("utf-8")) > MAX_INPUT_BYTES:
                yield current.rstrip()
                yield " "
                current = word.lstrip()
            else:
                current += word
        if current:
            yield current.rstrip()


def normalize(text, runtime):
    torch, tokenizer, model = runtime
    rendered = []
    for chunk in chunks(text):
        if not chunk or chunk.isspace():
            rendered.append(chunk)
            continue
        inputs = tokenizer("düzelt: " + chunk, return_tensors="pt")
        max_new_tokens = min(384, max(48, len(chunk.encode("utf-8")) + 48))
        with torch.inference_mode():
            output = model.generate(
                **inputs,
                max_new_tokens=max_new_tokens,
                num_beams=1,
                do_sample=False,
            )
        rendered.append(tokenizer.decode(output[0], skip_special_tokens=True).strip())
    return "".join(rendered).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--serve", action="store_true")
    args = parser.parse_args()

    if args.check:
        import torch  # noqa: F401
        import transformers  # noqa: F401
        print(json.dumps({"ok": True}))
        return
    if not args.serve:
        parser.error("--check or --serve is required")

    runtime = None
    for raw_line in sys.stdin:
        request_id = ""
        try:
            request = json.loads(raw_line)
            request_id = str(request.get("id", ""))
            text = request.get("text", "")
            if not isinstance(text, str) or not text.strip():
                raise ValueError("empty text")
            if runtime is None:
                runtime = load_runtime()
            response = {"id": request_id, "text": normalize(text, runtime)}
        except Exception as error:  # Keep the worker alive after one bad request.
            response = {"id": request_id, "error": f"{type(error).__name__}: {error}"}
        print(json.dumps(response, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
