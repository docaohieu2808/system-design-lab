"""Summarise tools/run-m03-cause.sh: per load step, the CPU of every container and of the host, per variant.

    python3 tools/aggregate-m03-cause.py modules/m03-load-balancing/results-cause 3 base3 base4 db1 ...

For each run the step windows come from k6's start (first time its container shows in the CPU samples): step i runs
t0 + i*20 s for 15 s; the first 3 s and last 1 s of each are left out (ramp up, k6 start-up uncertainty).
Numbers: cpu = percent of ONE core; throttled = percent of the time the container was held back by its CPU limit.
"""
import json
import statistics as st
import sys
from collections import defaultdict
from pathlib import Path

out, runs, variants = Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3:]
HOLD, GAP, SKIP_HEAD, SKIP_TAIL = 15, 5, 3, 1
agg = lambda xs: {"mean": round(st.mean(xs), 1), "min": round(min(xs), 1), "max": round(max(xs), 1)}


def load(path):
    rows = defaultdict(list)  # name -> [(t, a, b, c)]
    for line in path.read_text().splitlines():
        f = line.split("\t")
        rows[f[1]].append((float(f[0]), *[int(x) for x in f[2:]]))
    return rows


def window(rows, name, lo, hi):
    """(cpu%, throttled%) of one container (or host busy%, steal%) between lo and hi."""
    pts = [r for r in rows[name] if lo <= r[0] <= hi]
    if len(pts) < 2:
        return None
    a, b = pts[0], pts[-1]
    if name == "OTHER":
        return 100 * (b[1] - a[1]) / 1e6 / (b[0] - a[0]), 0
    if name == "HOST":
        return 100 * (b[1] - a[1]) / (b[3] - a[3]), 100 * (b[2] - a[2]) / (b[3] - a[3])
    dt = b[0] - a[0]
    return 100 * (b[1] - a[1]) / 1e6 / dt, 100 * (b[2] - a[2]) / 1e6 / dt


def group(name):
    if "-k6-run-" in name:
        return "k6"
    return name.rsplit("-", 1)[0].replace("sdlab-", "") if name.startswith("sdlab-") else name


res = {}
for v in variants:
    ceilings, slo, per_step = [], [], defaultdict(lambda: defaultdict(list))
    at_top = defaultdict(list)   # every metric at the run's own top step (the one that gave its ceiling)
    for k in range(1, runs + 1):
        j = json.loads((out / f"{v}-{k}.json").read_text())
        ceilings.append(max(s["succeeded_rps"] for s in j["steps"]))
        slo.append(max([s["succeeded_rps"] for s in j["steps"] if s["p99_ms"] < 50] or [0]))
        top = max(range(len(j["steps"])), key=lambda i: j["steps"][i]["succeeded_rps"])
        rows = load(out / f"{v}-{k}.cpu.tsv")
        t0 = min(r[0] for n, rs in rows.items() if "-k6-run-" in n for r in rs)
        for i, s in enumerate(j["steps"]):
            lo, hi = t0 + i * (HOLD + GAP) + SKIP_HEAD, t0 + i * (HOLD + GAP) + HOLD - SKIP_TAIL
            apps = [(n, window(rows, n, lo, hi)) for n in rows if group(n) == "app"]
            tmp = {"app_cpu_each": st.mean(w[0] for _, w in apps), "app_throttled": st.mean(w[1] for _, w in apps),
                   "app_cpu_max": max(w[0] for _, w in apps)}
            for g, key in (("traefik", "traefik"), ("db", "db")):
                n = next(n for n in rows if group(n) == g)
                w = window(rows, n, lo, hi)   # None when the sampler missed this container for the whole window
                if w:
                    tmp[f"{key}_cpu"], tmp[f"{key}_throttled"] = w
            n6 = next(n for n in rows if group(n) == "k6")
            tmp["k6_cpu"] = window(rows, n6, lo, hi)[0]
            tmp["host_busy"], tmp["host_steal"] = window(rows, "HOST", lo, hi)
            tmp["other_cpu"] = window(rows, "OTHER", lo, hi)[0]   # all non-sdlab containers together, % of one core
            tmp["succeeded_rps"], tmp["p99_ms"], tmp["dropped"] = s["succeeded_rps"], s["p99_ms"], s["dropped"]
            for key, val in tmp.items():
                per_step[s["asked_rps"]][key].append(val)
                if i == top:
                    at_top[key].append(val)
    res[v] = {"ceiling_rps": agg(ceilings), "rps_at_p99_under_50ms": agg(slo), "at_top_step": {k: agg(x) for k, x in at_top.items()}, "steps": {str(a): {k: agg(x) for k, x in d.items()} for a, d in per_step.items()}}
(out / "results.json").write_text(json.dumps(res, indent=1))

cols = ("succeeded_rps", "p99_ms", "app_cpu_each", "app_throttled", "traefik_cpu", "db_cpu", "db_throttled", "k6_cpu", "host_busy", "host_steal", "other_cpu")
for v in variants:
    print(f"\n{v}: ceiling {res[v]['ceiling_rps']}  at p99<50ms {res[v]['rps_at_p99_under_50ms']}")
    print("  at each run's top step: " + "  ".join(f"{k}={d['mean']}" for k, d in res[v]["at_top_step"].items()))
    print("asked  " + "  ".join(f"{c[:13]:>13}" for c in cols))
    for a, d in res[v]["steps"].items():
        print(f"{a:>5}  " + "  ".join(f"{d[c]['mean'] if c in d else '-':>13}" for c in cols))
