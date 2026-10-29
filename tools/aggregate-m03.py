"""Summarise Module 3 runs into results.json: mean / min / max over runs.

    python3 tools/aggregate-m03.py modules/m03-load-balancing/results 3
"""
import json
import statistics as st
import sys
from collections import defaultdict
from pathlib import Path

out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": min(xs), "max": max(xs)}
res = {"runs": runs, "scale": {}, "kill": {}, "pause": {}, "slow": {}}
for n in (1, 2, 3, 4):
    data = [json.loads((out / f"scale-{n}-{k}.json").read_text()) for k in range(1, runs + 1)]
    ceilings = [max(s["succeeded_rps"] for s in d["steps"]) for d in data]
    steps = []
    for i, s in enumerate(data[0]["steps"]):
        steps.append({"asked_rps": s["asked_rps"], **{f: agg([d["steps"][i][f] for d in data])
                      for f in ("succeeded_rps", "p50_ms", "p99_ms", "dropped")}})
    peak = defaultdict(float)
    for k in range(1, runs + 1):
        for line in (out / f"scale-{n}-{k}.cpu.tsv").read_text().splitlines():
            name, cpu = line.split("\t")
            if name == "HOST" or name.startswith("sdlab-") or "-k6-run-" in name:
                key = "k6" if "-k6-run-" in name else name
                peak[key] = max(peak[key], float(cpu.rstrip("%")))
    res["scale"][n] = {"ceiling_rps": agg(ceilings), "steps": steps, "peak_cpu_pct": dict(peak)}
for kind, keys in (("kill", (3, 4)), ("pause", ("no", "yes")), ("slow", ("wrr", "p2c"))):
    for key in keys:
        data = [json.loads((out / f"{kind}-{key}-{k}.json").read_text()) for k in range(1, runs + 1)]
        res[kind][key] = {p: {f: agg([d[p][f] for d in data]) for f in data[0][p]} for p in ("before", "after")}
(out / "results.json").write_text(json.dumps(res, indent=1))
for n, r in res["scale"].items():
    print(f"scale {n}: ceiling {r['ceiling_rps']}  host peak {r['peak_cpu_pct'].get('HOST')}%  traefik {r['peak_cpu_pct'].get('sdlab-traefik-1')}%")
for kind in ("kill", "pause", "slow"):
    for key, r in res[kind].items():
        print(f"{kind} {key}: " + "  ".join(f"{p} p99 {r[p]['p99_ms']['mean']} failed {r[p]['failed']['mean']}" for p in ("before", "after")))
