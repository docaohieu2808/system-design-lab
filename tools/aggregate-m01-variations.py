"""Summarise the Module 1 variation runs into results.json.  python3 tools/aggregate-m01-variations.py <dir> <runs>
Per arm and per asked step: succeeded_rps, dropped, p50/p99 (mean, min, max); plus the mean k6 and app cores at the top step."""
import json
import statistics as st
import sys
from pathlib import Path

out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}
R = range(1, runs + 1)


def cores(tag, prefix, start_frac=0.0):
    """Mean cores of a container over the whole test (cumulative usage_usec) and over the last step window (the final 25 s)."""
    rows = [(float(l.split("\t")[0]), int(l.split("\t")[2])) for l in (out / f"{tag}.cpu.tsv").read_text().splitlines() if l.split("\t")[1].startswith(prefix)]
    if len(rows) < 2:
        return 0.0
    end = rows[-1][0]
    last = [r for r in rows if r[0] >= end - 20]
    return (last[-1][1] - last[0][1]) / 1e6 / (last[-1][0] - last[0][0]) if len(last) > 1 else 0.0


res = {"runs": runs, "arms": {}}
for arm in ("base", "k6half", "app1"):
    data = [json.loads((out / f"{arm}-{k}.json").read_text()) for k in R]
    steps = [{"asked_rps": s["asked_rps"], **{f: agg([d["steps"][i][f] for d in data]) for f in ("succeeded_rps", "dropped", "p50_ms", "p95_ms", "p99_ms")}}
             for i, s in enumerate(data[0]["steps"])]
    top = {"k6_cores_last_20s": agg([cores(f"{arm}-{k}", "sdlab-k6") for k in R]), "app_cores_last_20s": agg([cores(f"{arm}-{k}", "sdlab-app-1") for k in R]),
           "background_busy_pct": agg([float((out / f"{arm}-{k}.gate").read_text().split()[0].split("=")[1]) for k in R])}
    res["arms"][arm] = {"steps": steps, **top}
(out / "results.json").write_text(json.dumps(res, indent=1))
print(json.dumps({a: {"top_step": d["steps"][-1], **{k: v for k, v in d.items() if k != "steps"}} for a, d in res["arms"].items()}, indent=1))
