"""Summarise tools/run-m01-finer.sh into results.json.  python3 tools/aggregate-m01-finer.py <dir> <runs>
Per asked rate (the last step of each two-step ladder): succeeded_rps, dropped (not sent), p50/p95/p99 (mean, min, max),
plus the mean k6 and app cores over the last 20 s and the share of requests that did not get a 302."""
import json
import statistics as st
import sys
from pathlib import Path

out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}
R = range(1, runs + 1)


def cores(tag, prefix):
    """Mean cores of a container over the last 20 s of its cumulative usage_usec samples."""
    rows = [(float(l.split("\t")[0]), int(l.split("\t")[2])) for l in (out / f"{tag}.cpu.tsv").read_text().splitlines() if l.split("\t")[1].startswith(prefix)]
    last = [r for r in rows if rows and r[0] >= rows[-1][0] - 20]
    return (last[-1][1] - last[0][1]) / 1e6 / (last[-1][0] - last[0][0]) if len(last) > 1 else 0.0


arms = sorted({int(p.name[1:].split("-")[0]) for p in out.glob("r*-1.json")})
res = {"runs": runs, "asked": {}}
for asked in arms:
    data = [json.loads((out / f"r{asked}-{k}.json").read_text())["steps"][-1] for k in R]
    assert all(d["asked_rps"] == asked for d in data)
    res["asked"][asked] = {**{f: agg([d[f] for d in data]) for f in ("succeeded_rps", "dropped", "p50_ms", "p95_ms", "p99_ms")},
                           "k6_cores_last_20s": agg([cores(f"r{asked}-{k}", "sdlab-k6") for k in R]),
                           "app_cores_last_20s": agg([cores(f"r{asked}-{k}", "sdlab-app-1") for k in R]),
                           "background_busy_pct": agg([float((out / f"r{asked}-{k}.gate").read_text().split()[0].split("=")[1]) for k in R])}
# the step that precedes every asked step in its ladder (warm-up, also a free extra look at this session's speed)
w = [json.loads((out / f"r{a}-{k}.json").read_text())["steps"][0] for a in arms for k in R]
res["warmup_step_all_ladders"] = {f: agg([x[f] for x in w]) for f in ("succeeded_rps", "dropped", "p50_ms", "p99_ms")} | {"asked_rps": w[0]["asked_rps"], "ladders": len(w)}
(out / "results.json").write_text(json.dumps(res, indent=1))
print(json.dumps({a: {f: v[f]["mean"] for f in ("succeeded_rps", "dropped", "p99_ms")} | {"p99_range": [v["p99_ms"]["min"], v["p99_ms"]["max"]]} for a, v in res["asked"].items()}, indent=1))
