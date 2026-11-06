"""Summarise the Module 7.3 hot-key fix runs into results.json.  python3 tools/aggregate-m07-hotfix.py <dir> <runs>

Per arm (even / hot / cache): rps, failed %, dropped, p99, hot-code p99, other-codes p99, the hot shard's share of the
lookups the shards answered, its share of ALL requests (cache hits counted), cache hits, and CPU in cores
(mean over the load window) of k6, the app and each shard (peak 1 s too for the hot shard).
The hot shard is the one that answered the most lookups in the same run's plain hot arm (hot, or hot20 in the extras).
Usage: aggregate-m07-hotfix.py <dir> <runs> [even,hot,cache | even,r600,hot20]
"""
import json
import statistics as st
import sys
from pathlib import Path

out, runs = Path(sys.argv[1]), int(sys.argv[2])
ARMS = (sys.argv[3] if len(sys.argv) > 3 else "even,hot,cache").split(",")
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}
NAMES = {"k6": "sdlab-k6", "app": "sdlab-app-1", "db": "sdlab-db-1", "db2": "sdlab-db2-1", "db3": "sdlab-db3-1"}


def cores(path, start, end):
    """Mean cores per container over [start, end] from cumulative cgroup usage_usec lines."""
    pts = {}
    for line in path.read_text().splitlines():
        f = line.split("\t")
        if f[1] == "HOST" or f[1] == "OTHER":
            continue
        pts.setdefault(f[1], []).append((float(f[0]), int(f[2])))
    res = {}
    for key, prefix in NAMES.items():
        for n, rows in pts.items():
            if n.startswith(prefix):
                w = [r for r in rows if start <= r[0] <= end]
                if len(w) > 1:
                    res[key] = (w[-1][1] - w[0][1]) / 1e6 / (w[-1][0] - w[0][0])
    return res


def window(path):
    """Load window = the stretch where the app container is busy (>= 0.05 cores between samples)."""
    rows = [(float(l.split("\t")[0]), int(l.split("\t")[2])) for l in path.read_text().splitlines() if l.split("\t")[1].startswith("sdlab-app")]
    busy = [rows[i][0] for i in range(1, len(rows)) if (rows[i][1] - rows[i - 1][1]) / 1e6 / max(1e-9, rows[i][0] - rows[i - 1][0]) >= 0.05]
    return (busy[0], busy[-1]) if busy else (0, 0)


res = {"runs": runs, "arms": {}}
raw = {a: [] for a in ARMS}
for k in range(1, runs + 1):
    for arm in raw:
        ref = "hot" if "hot" in raw else "hot20"  # the shard that answered the most lookups in the plain hot arm of the same run
        hot_shards = json.loads((out / f"{ref}-{k}.shards.json").read_text())["lookups_per_shard"]
        hs = hot_shards.index(max(hot_shards))
        r = json.loads((out / f"{arm}-{k}.json").read_text())
        s = json.loads((out / f"{arm}-{k}.shards.json").read_text())
        per, hits = s["lookups_per_shard"], s.get("hot_cache_hits", 0)
        t0, t1 = window(out / f"{arm}-{k}.cpu.tsv")
        c = cores(out / f"{arm}-{k}.cpu.tsv", t0, t1)
        gate = (out / f"{arm}-{k}.gate").read_text().split()
        raw[arm].append({**{f: r[f] for f in ("rps", "failed_pct", "dropped", "p99_ms", "hot_p99_ms", "cold_p50_ms", "cold_p99_ms") if r[f] is not None},
                         "hot_shard_share_of_shard_lookups_pct": 100 * per[hs] / max(1, sum(per)),
                         "hot_shard_share_of_all_requests_pct": 100 * per[hs] / max(1, sum(per) + hits),
                         "shard_lookups": sum(per), "cache_hits": hits, "hot_shard_index": hs,
                         "k6_cores": c.get("k6", 0), "app_cores": c.get("app", 0), "hot_shard_cores": c.get(["db", "db2", "db3"][hs], 0),
                         "background_busy_pct": float(gate[0].split("=")[1])})
for arm, rows in raw.items():
    res["arms"][arm] = {f: agg([r[f] for r in rows]) for f in rows[0]}
res["per_run"] = raw
(out / "results.json").write_text(json.dumps(res, indent=1))
print(json.dumps({a: {k: v for k, v in d.items()} for a, d in res["arms"].items()}, indent=1))
