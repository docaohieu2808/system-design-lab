"""Summarise Module 12 runs into results.json.  python3 tools/aggregate-m12.py modules/m12-contention/results 3
Reads tickets-K.json (the four database ways, and redis_lock when LOCK=redis was used), tickets-stall-K.json and
tickets-stall-fence-K.json (the stalled-holder arms); each with its .gate (quiet-machine reading) and .cpu.tsv (CPU samples)."""
import json
import re
import statistics as st
import sys
from pathlib import Path

out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}


def last_json(p):
    return json.loads(p.read_text().strip().splitlines()[-1])


def cores(tag, part):
    first, last = {}, {}
    for l in (out / f"{tag}.cpu.tsv").read_text().splitlines():
        t, name, u, *_ = l.split("\t")
        if part in name and name not in ("HOST", "OTHER"):
            first.setdefault(name, (float(t), int(u))); last[name] = (float(t), int(u))
    return round(sum((last[n][1] - first[n][1]) / 1e6 / max(last[n][0] - first[n][0], 1) for n in first), 3)


def gate(tag):
    f = out / f"{tag}.gate"
    return float(re.search(r"background_busy_pct=(\d+)", f.read_text()).group(1)) if f.exists() else None


res = {"runs": runs, "seats": 100, "buyers": 1000}
for prefix in ("tickets", "tickets-stall", "tickets-stall-fence"):
    files = [out / f"{prefix}-{k}.json" for k in range(1, runs + 1)]
    if not all(f.exists() for f in files):
        continue
    rows = [last_json(f) for f in files]
    for m in rows[0]:
        if isinstance(rows[0][m], dict):
            res[m] = {f: agg([r[m][f] for r in rows]) for f in ("orders", "oversold", "ms")}
    g = [gate(f"{prefix}-{k}") for k in range(1, runs + 1)]
    if None not in g:
        res.setdefault("background_busy_pct", {})[prefix] = agg(g)
    if all((out / f"{prefix}-{k}.cpu.tsv").exists() for k in range(1, runs + 1)):
        res.setdefault("cores", {})[prefix] = {p: agg([cores(f"{prefix}-{k}", p) for k in range(1, runs + 1)])
                                                for p in ("app", "db", "redis")}
(out / "results.json").write_text(json.dumps(res, indent=1)); print(json.dumps(res, indent=1))
