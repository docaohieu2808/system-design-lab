"""Summarise the Module 4 cache-size sweep into results.json.  python3 tools/aggregate-m04-size.py <dir> <runs>"""
import json
import statistics as st
import sys
from pathlib import Path

out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}
R = range(1, runs + 1)


def cores(tag, prefix):
    rows = [(float(l.split("\t")[0]), int(l.split("\t")[2])) for l in (out / f"{tag}.cpu.tsv").read_text().splitlines() if l.split("\t")[1].startswith(prefix)]
    return (rows[-1][1] - rows[0][1]) / 1e6 / (rows[-1][0] - rows[0][0]) if len(rows) > 1 else 0


res = {"runs": runs, "arms": {}}
for arm in ("z1", "z2", "z4", "z8", "u4", "u8"):
    rows = []
    for k in R:
        t = f"{arm}-{k}"
        a, r = json.loads((out / f"{t}.app.json").read_text()), json.loads((out / f"{t}.json").read_text())
        redis = dict(l.split(":") for l in (out / f"{t}.redis.txt").read_text().splitlines() if ":" in l)
        rows.append({"hit_ratio_pct": 100 * a["cache_hits"] / max(1, a["cache_hits"] + a["cache_misses"]),
                     "db_queries_per_s": a["db_queries"] / 60, "evicted_keys": int(redis["evicted_keys"]),
                     "used_memory_mb": int(redis["used_memory"]) / 1048576, **{f: r[f] for f in ("rps", "p50_ms", "p99_ms", "failed_pct")},
                     "k6_cores": cores(t, "sdlab-k6"), "app_cores": cores(t, "sdlab-app-1"),
                     "background_busy_pct": float((out / f"{t}.gate").read_text().split()[0].split("=")[1])})
    res["arms"][arm] = {f: agg([r[f] for r in rows]) for f in rows[0]}
(out / "results.json").write_text(json.dumps(res, indent=1))
print(json.dumps(res, indent=1))
