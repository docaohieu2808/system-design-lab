"""Summarise Module 8 runs into results.json.  python3 tools/aggregate-m08.py modules/m08-cap/results 3

Phases by time since start: before the cut (< 10 s), during it (10.5-19.5 s), after it heals (> 22 s).
"Behind" = how many writes the value read is behind the newest write at that moment (one write every ~200 ms)."""
import json
import statistics as st
import sys
from collections import defaultdict
from pathlib import Path

out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)} if xs else None
phase = lambda t: "before" if t < 10000 else "during" if 10500 <= t <= 19500 else "after" if t > 22000 else None
res = {"runs": runs}
for kind in ("etcd", "redis"):
    per_run = []
    for k in range(1, runs + 1):
        counts, behind = defaultdict(lambda: [0, 0]), defaultdict(list)
        latest = 0
        for line in (out / f"{kind}-{k}.log").read_text().splitlines():
            t, op, node, ok, val = line.split()
            t, p = int(t), phase(int(t))
            if op == "write" and node in ("e2", "r1") and ok == "ok":
                latest = int(val)
            if p is None:
                continue
            counts[f"{op}-{node}-{p}"][0 if ok == "ok" else 1] += 1
            if op in ("read-local", "read") and ok == "ok" and val.isdigit():
                behind[f"{op}-{node}-{p}"].append(latest - int(val))
        per_run.append({**{f"{key}_ok_pct": round(100 * c[0] / sum(c), 1) for key, c in counts.items()},
                        **{f"{key}_behind_max": max(v) for key, v in behind.items()}})
    keys = sorted({k for r in per_run for k in r})
    res[kind] = {key: agg([r[key] for r in per_run if key in r]) for key in keys}
(out / "results.json").write_text(json.dumps(res, indent=1))
print(json.dumps(res, indent=1))
