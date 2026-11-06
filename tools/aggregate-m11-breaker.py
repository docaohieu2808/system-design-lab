"""Summarise the Module 11.4 breaker runs into results.json.  python3 tools/aggregate-m11-breaker.py <dir> <runs>"""
import json
import statistics as st
import sys
from pathlib import Path

out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}


def cores(path, prefix):
    rows = [(float(l.split("\t")[0]), int(l.split("\t")[2])) for l in path.read_text().splitlines() if l.split("\t")[1].startswith(prefix)]
    return (rows[-1][1] - rows[0][1]) / 1e6 / (rows[-1][0] - rows[0][0]) if len(rows) > 1 else 0


res = {"runs": runs, "arms": {}}
def common(arm, k, r):
    r["k6_cores"] = cores(out / f"{arm}-{k}.cpu.tsv", "sdlab-k6")
    r["app_cores"] = cores(out / f"{arm}-{k}.cpu.tsv", "sdlab-app-1")
    r["background_busy_pct"] = float((out / f"{arm}-{k}.gate").read_text().split()[0].split("=")[1])


for arm in ("g500", "g2000", "cap2", "cap4", "cap8"):  # goodput per offered step: good, slow, refused, failed per second
    runs_ = [json.loads((out / f"{arm}-{k}.json").read_text()) for k in range(1, runs + 1)]
    res["arms"][arm] = {"steps": [{"offered": s["offered"], **{f: agg([r["steps"][i][f] for r in runs_]) for f in ("goodput", "slow_per_s", "refused_per_s", "failed_per_s")}}
                                  for i, s in enumerate(runs_[0]["steps"])]}
    extra = [{} for _ in runs_]
    for k, e in enumerate(extra, 1):
        common(arm, k, e)
    res["arms"][arm].update({f: agg([e[f] for e in extra]) for f in extra[0]})
for arm in ("off", "simple", "single", "d500off", "d500on"):
    rows = []
    for k in range(1, runs + 1):
        r = json.loads((out / f"{arm}-{k}.json").read_text())
        r["dep_calls"] = json.loads((out / f"{arm}-{k}.dep.json").read_text())["dep_calls"]
        common(arm, k, r)
        rows.append(r)
    res["arms"][arm] = {f: agg([r[f] for r in rows]) for f in rows[0]}
(out / "results.json").write_text(json.dumps(res, indent=1))
print(json.dumps(res, indent=1))
