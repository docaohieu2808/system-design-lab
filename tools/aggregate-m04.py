"""Summarise Module 4 runs into results.json (mean / min / max over runs).

    python3 tools/aggregate-m04.py modules/m04-caching/results 3
"""
import json
import statistics as st
import sys
from pathlib import Path

out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}


def series(path):
    rows = []
    for line in path.read_text().splitlines():
        t, q, k = line.split("\t")
        if int(q) >= 0 and int(k) >= 0:
            rows.append((float(t), int(q), int(k)))
    return rows


def per_second(rows, start=10.0):
    """Database queries in each 1-second window after `start` s."""
    out_, i = [], 0
    for t0, q0, _ in rows:
        if t0 < start:
            continue
        later = [q for t, q, _ in rows if t0 + 1.0 <= t < t0 + 1.6]
        if later:
            out_.append(later[0] - q0)
    return out_


res = {"runs": runs, "hit": {}, "flush": {}, "expiry": {}}
for cfg in ("nocache", "uniform", "zipf"):
    k6 = [json.loads((out / f"hit-{cfg}-{k}.json").read_text()) for k in range(1, runs + 1)]
    app = [json.loads((out / f"hit-{cfg}-{k}.app.json").read_text()) for k in range(1, runs + 1)]
    ratio = [100 * a["cache_hits"] / max(1, a["cache_hits"] + a["cache_misses"]) for a in app]
    res["hit"][cfg] = {"hit_ratio_pct": agg(ratio), "db_queries_per_s": agg([a["db_queries"] / 60 for a in app]),
                       **{f: agg([r[f] for r in k6]) for f in ("rps", "p50_ms", "p99_ms", "failed_pct")}}
for sf in ("0", "1"):
    rows = []
    for k in range(1, runs + 1):
        s = series(out / f"flush-{sf}-{k}.stats.tsv")
        flush = next(i for i in range(1, len(s)) if s[i][0] > 20 and s[i][2] < 0.2 * s[i - 1][2])
        t, q, _ = s[flush]
        after = [r for r in s if t <= r[0] <= t + 3.0]
        rebuilt, distinct = after[-1][1] - q, max(1, after[-1][2])
        r6 = json.loads((out / f"flush-{sf}-{k}.json").read_text())
        rows.append({"db_queries_3s_after_flush": rebuilt, "pages_rebuilt": distinct,
                     "queries_per_page": rebuilt / distinct, "p99_ms": r6["p99_ms"], "max_ms": r6["max_ms"]})
    res["flush"][sf] = {f: agg([r[f] for r in rows]) for f in rows[0]}
for j in ("0", "0.5"):
    rows = []
    for k in range(1, runs + 1):
        ps = per_second(series(out / f"expiry-{j}-{k}.stats.tsv"))
        r6 = json.loads((out / f"expiry-{j}-{k}.json").read_text())
        rows.append({"peak_db_queries_per_s": max(ps), "median_db_queries_per_s": st.median(ps),
                     "p99_ms": r6["p99_ms"]})
    res["expiry"][j] = {f: agg([r[f] for r in rows]) for f in rows[0]}
(out / "results.json").write_text(json.dumps(res, indent=1))
print(json.dumps(res, indent=1))
