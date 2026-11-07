"""Summarise tools/run-m06-synccost.sh into results.json.  python3 tools/aggregate-m06-synccost.py <dir> <runs>
Per arm (async, sync): succeeded_rps, p50/p95/p99/avg (mean, min, max over runs), dropped, not_201, timeouts, and the mean app / db / db2
cores over the 30 s window. If stopped-1.json exists (one run, synchronous standby stopped) it is added as "stopped_single_run"."""
import json
import statistics as st
import sys
from pathlib import Path

out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}
R = range(1, runs + 1)


def cores(tag, name, secs):
    """Mean cores of one container over the last `secs` seconds of its cumulative usage_usec samples."""
    rows = [(float(l.split("\t")[0]), int(l.split("\t")[2])) for l in (out / f"{tag}.cpu.tsv").read_text().splitlines() if l.split("\t")[1] == name]
    last = [r for r in rows if r[0] >= rows[-1][0] - secs]
    return (last[-1][1] - last[0][1]) / 1e6 / (last[-1][0] - last[0][0]) if len(last) > 1 else 0.0


res = {"runs": runs}
for arm in ("async", "sync"):
    d = [json.loads((out / f"{arm}-{k}.json").read_text()) for k in R]
    res[arm] = {**{f: agg([x[f] for x in d]) for f in ("succeeded_rps", "p50_ms", "p95_ms", "p99_ms", "avg_ms", "max_ms", "dropped", "not_201", "timeouts")},
                **{f"{n}_cores": agg([cores(f"{arm}-{k}", f"sdlab-{n}-1", 30) for k in R]) for n in ("app", "db", "db2")},
                "background_busy_pct": agg([float((out / f"{arm}-{k}.gate").read_text().split()[0].split("=")[1]) for k in R])}
if (out / "stopped-1.json").exists():
    res["stopped_single_run"] = json.loads((out / "stopped-1.json").read_text())
    if (out / "stopped-1.after.txt").exists():
        res["stopped_single_run"]["after"] = dict(l.split(": ", 1) for l in (out / "stopped-1.after.txt").read_text().splitlines())
probes = sorted(out.glob("probe-*.json"))
if probes:   # one run per rate and arm, used only to pick the moderate rate
    res["probe_single_runs"] = {p.stem[6:]: {f: json.loads(p.read_text())[f] for f in ("succeeded_rps", "dropped", "p50_ms", "p99_ms")} for p in probes}
(out / "results.json").write_text(json.dumps(res, indent=1))
print(json.dumps(res, indent=1))
