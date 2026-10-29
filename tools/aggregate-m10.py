"""Summarise Module 10 runs into results.json.  python3 tools/aggregate-m10.py modules/m10-async/results 3"""
import json
import statistics as st
import sys
from pathlib import Path

out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}


def load(path):
    """k6 writes pretty-printed JSON; the drills print one JSON line after any log lines."""
    text = path.read_text().strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return json.loads(text.splitlines()[-1])


j = lambda n: [load(out / f"{n}-{k}.json") for k in range(1, runs + 1)]
res = {"runs": runs}
for q in ("0", "1"):
    res[f"inline_queue{q}"] = {f: agg([r[f] for r in j(f"inline-{q}")]) for f in ("create_p50_ms", "create_p99_ms")}
for w in ("1", "16"):
    rows = j(f"lag-{w}")
    res[f"lag_workers{w}"] = {"done": agg([r["done"] for r in rows]), "wait_p50_ms": agg([r["wait_ms"]["p50"] for r in rows]),
                              "wait_p99_ms": agg([r["wait_ms"]["p99"] for r in rows]), "left_in_stream": agg([r["stream_len"] - r["done"] for r in rows])}
for i in ("0", "1"):
    res[f"charges_idem{i}"] = {f: agg([r[f] for r in j(f"charges-{i}")]) for f in ("crashes", "charges", "jobs_charged", "double_charges")}
for d in ("0", "3"):
    res[f"poison_dlq{d}"] = {f: agg([r[f] for r in j(f"poison-{d}")]) for f in ("good_done_in_10s", "poison_attempts", "parked_in_dlq")}
for r_ in ("immediate", "backoff"):
    rows = j(f"storm-{r_}")
    res[f"storm_{r_}"] = {p: {f: agg([r[p][f] for r in rows]) for f in ("attempts", "created", "gave_up")} for p in ("before", "during", "after")}
(out / "results.json").write_text(json.dumps(res, indent=1))
print(json.dumps(res, indent=1))
