"""Summarise tools/run-m06-reads.sh: per arm, the highest rate the stack sustained and the CPU at every step.

    python3 tools/aggregate-m06-reads.py modules/m06-replication/results-reads 3 A B C D

Sustained step = succeeded req/s within 1% of the asked rate and 0 dropped iterations. A run's ceiling is the highest
asked rate that is sustained; the peak is the most succeeded req/s at any step (the saturation throughput). CPU windows come from k6's start (first sample of its container): step i runs
t0 + i*(HOLD+GAP) for HOLD s; the first 3 s and last 1 s are left out. cpu = percent of ONE core; throttled = percent
of the time the container was held back by its CPU limit.
"""
import json
import statistics as st
import sys
from collections import defaultdict
from pathlib import Path

out, runs, arms = Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3:]
GAP, SKIP_HEAD, SKIP_TAIL = 5, 3, 1
agg = lambda xs: {"mean": round(st.mean(xs), 1), "min": round(min(xs), 1), "max": round(max(xs), 1)}


def load(path):
    rows = defaultdict(list)
    for line in path.read_text().splitlines():
        f = line.split("\t")
        rows[f[1]].append((float(f[0]), *[int(x) for x in f[2:]]))
    return rows


def window(rows, name, lo, hi):
    pts = [r for r in rows[name] if lo <= r[0] <= hi]
    if len(pts) < 2:
        return None
    a, b = pts[0], pts[-1]
    if name == "HOST":
        return 100 * (b[1] - a[1]) / (b[3] - a[3]), 100 * (b[2] - a[2]) / (b[3] - a[3])
    dt = b[0] - a[0]
    return 100 * (b[1] - a[1]) / 1e6 / dt, 100 * (b[2] - a[2]) / 1e6 / dt


def group(name):
    if "-k6-run-" in name:
        return "k6"
    return name.rsplit("-", 1)[0].replace("sdlab-", "") if name.startswith("sdlab-") else name


sustained = lambda s: s["succeeded_rps"] >= 0.99 * s["asked_rps"] and s["dropped"] == 0
res = {}
for a in arms:
    ceilings, peaks, backgrounds, per_step = [], [], [], defaultdict(lambda: defaultdict(list))
    for k in range(1, runs + 1):
        j = json.loads((out / f"{a}-{k}.json").read_text())
        ok = [s["asked_rps"] for s in j["steps"] if sustained(s)]
        ceilings.append(max(ok) if ok else 0)
        peaks.append(max(s["succeeded_rps"] for s in j["steps"]))   # most answered per second at any step, once past the ceiling
        backgrounds.append(int(next(w.split("=")[1] for w in (out / f"{a}-{k}.gate").read_text().split() if w.startswith("background_busy_pct"))))
        rows = load(out / f"{a}-{k}.cpu.tsv")
        t0 = min(r[0] for n, rs in rows.items() if "-k6-run-" in n for r in rs)
        hold = j["hold_s"]
        for i, s in enumerate(j["steps"]):
            lo, hi = t0 + i * (hold + GAP) + SKIP_HEAD, t0 + i * (hold + GAP) + hold - SKIP_TAIL
            tmp = {"succeeded_rps": s["succeeded_rps"], "dropped": s["dropped"], "p99_ms": s["p99_ms"]}
            for g in ("app", "db", "db2", "k6"):
                n = next(n for n in rows if group(n) == g)
                tmp[f"{g}_cpu"], tmp[f"{g}_throttled"] = window(rows, n, lo, hi)
            tmp["host_busy"], tmp["host_steal"] = window(rows, "HOST", lo, hi)
            for key, val in tmp.items():
                per_step[s["asked_rps"]][key].append(val)
    res[a] = {"ceiling_rps": agg(ceilings), "ceilings_per_run": ceilings, "peak_succeeded_rps": agg(peaks), "background_busy_pct": agg(backgrounds),
              "steps": {str(r): {k: agg(x) for k, x in d.items()} for r, d in per_step.items()}}
(out / "results.json").write_text(json.dumps(res, indent=1))

cols = ("succeeded_rps", "dropped", "p99_ms", "app_cpu", "app_throttled", "db_cpu", "db_throttled", "db2_cpu", "db2_throttled", "k6_cpu", "host_busy", "host_steal")
for a in arms:
    print(f"\n{a}: ceiling {res[a]['ceiling_rps']} per run {res[a]['ceilings_per_run']}  peak served {res[a]['peak_succeeded_rps']}  background {res[a]['background_busy_pct']['mean']}%")
    print("asked  " + "  ".join(f"{c[:13]:>13}" for c in cols))
    for r, d in res[a]["steps"].items():
        print(f"{r:>5}  " + "  ".join(f"{d[c]['mean']:>13}" for c in cols))
