"""Summarise Module 7 runs into results.json.  python3 tools/aggregate-m07.py modules/m07-partitioning/results 3"""
import json
import re
import statistics as st
import sys
from collections import defaultdict
from pathlib import Path

out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}
R = range(1, runs + 1)
res = {"runs": runs}
rh = [json.loads((out / f"rehash-{k}.json").read_text()) for k in R]
res["rehash"] = {**{f: rh[0][f] for f in ("keys", "from_shards", "to_shards", "vnodes_per_shard", "consistent_keys_per_shard_after")},
                 "moved_modulo_pct": round(rh[0]["moved_modulo_pct"], 2), "moved_consistent_pct": round(rh[0]["moved_consistent_pct"], 2)}
res["hot"] = {}
for hot in ("0", "50"):
    rows = [json.loads((out / f"hot-{hot}-{k}.json").read_text()) for k in R]
    shares, peaks = [], defaultdict(list)
    for k in R:
        per = json.loads((out / f"hot-{hot}-{k}.shards.json").read_text())["lookups_per_shard"]
        shares.append([round(100 * x / max(1, sum(per)), 1) for x in per])
        pk = defaultdict(float)
        for line in (out / f"hot-{hot}-{k}.cpu.tsv").read_text().splitlines():
            n, c = line.split("\t")
            pk[n] = max(pk[n], float(c.rstrip("%")))
        for n, c in pk.items():
            peaks[n].append(c)
    res["hot"][hot] = {**{f: agg([r[f] for r in rows if r[f] is not None] or [0]) for f in ("rps", "failed_pct", "p99_ms", "hot_p99_ms", "cold_p50_ms", "cold_p99_ms")},
                       "share_pct_per_shard_run1": shares[0], "peak_cpu_pct": {n: agg(v) for n, v in sorted(peaks.items())}}
ids = defaultdict(list)
for k in R:
    txt = (out / f"ids-{k}.txt").read_text()
    for kind in ("bigint", "uuid4", "uuid7"):
        m = re.search(rf"insert-{kind}\s*\nINSERT 0 1000000\s*\nTime: ([\d.]+) ms", txt) or re.search(rf"insert-{kind}.*?Time: ([\d.]+) ms", txt, re.S)
        ids[f"{kind}_insert_s"].append(float(m.group(1)) / 1000)
        size = re.search(rf"index-mb\|ids_{kind}\|([\d.]+)", txt)
        ids[f"{kind}_index_mb"].append(float(size.group(1)))
res["ids"] = {f: agg(v) for f, v in ids.items()}
(out / "results.json").write_text(json.dumps(res, indent=1))
print(json.dumps(res, indent=1))
