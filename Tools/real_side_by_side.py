"""Puts every model's cleanup of the same real transcripts side by side.

    python3 Tools/real_side_by_side.py EVAL_DIR [BASELINE_MODEL]

Reads EVAL_DIR/cleanup-real-<model>.tsv (written by cleanup_eval --real) and prints, per model,
how often it agrees word for word with the baseline (default: the app's gemma4:e4b-it-qat), then
every sentence where the models disagree, so you can judge them yourself. Also writes
EVAL_DIR/real-side-by-side.tsv for a spreadsheet.
"""
import re
import sys
from pathlib import Path

eval_dir = Path(sys.argv[1])
baseline = (sys.argv[2] if len(sys.argv) > 2 else "gemma4:e4b-it-qat").replace(":", "_")


def words(s: str) -> list[str]:
    return [w for w in re.split(r"[^\w'’]+", s.lower()) if w]


outputs = {}
for f in sorted(eval_dir.glob("cleanup-real-*.tsv")):
    model = f.stem.removeprefix("cleanup-real-")
    rows = [line.split("\t") for line in f.read_text(encoding="utf-8").splitlines() if line.count("\t") >= 2]
    outputs[model] = {raw: out for _, raw, out in rows}

if baseline not in outputs:
    sys.exit(f"no cleanup-real-{baseline}.tsv in {eval_dir}")
models = [baseline] + [m for m in outputs if m != baseline]
raws = list(outputs[baseline])

print(f"Agreement with {baseline} (same words) on {len(raws)} real transcripts:")
for m in models[1:]:
    same = sum(words(outputs[m].get(r, "")) == words(outputs[baseline][r]) for r in raws)
    print(f"  {m:28} {same}/{len(raws)}")

table = ["raw\t" + "\t".join(models)]
print("\nSentences where the models disagree:")
for r in raws:
    outs = [outputs[m].get(r, "") for m in models]
    table.append("\t".join([r] + outs))
    if len({" ".join(words(o)) for o in outs}) > 1:
        print(f"\nRAW  {r}")
        for m, o in zip(models, outs):
            print(f"  {m:28} {o}")
(eval_dir / "real-side-by-side.tsv").write_text("\n".join(table) + "\n", encoding="utf-8")
