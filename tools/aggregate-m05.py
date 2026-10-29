"""Summarise Module 5 runs into results.json (mean / min / max over runs).

    python3 tools/aggregate-m05.py modules/m05-database/results 3
"""
import json
import re
import statistics as st
import sys
from pathlib import Path

out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}
R = range(1, runs + 1)
j = lambda name: json.loads((out / name).read_text())


def plan(name):
    p = j(name)[0]
    node = p["Plan"]
    while "Plans" in node and "Rows Removed by Filter" not in node and node.get("Node Type") != "Index Scan":
        node = node["Plans"][0]
    return {"execution_ms": p["Execution Time"], "rows_removed_by_filter": node.get("Rows Removed by Filter", 0),
            "node": node["Node Type"]}


def bench(name):
    t = (out / name).read_text()
    tps = re.search(r"tps = ([\d.]+)", t)
    lat = re.search(r"latency average = ([\d.]+) ms", t)
    return {"tps": float(tps.group(1)) if tps else 0.0, "latency_avg_ms": float(lat.group(1)) if lat else 0.0,
            "too_many_clients": len(re.findall(r"too many clients", t))}


res = {"runs": runs}
before = [plan(f"index-plan-before-{k}.json") for k in R]
after = [plan(f"index-plan-after-{k}.json") for k in R]
res["index"] = {
    "plan_before": {"node": before[0]["node"], **{f: agg([p[f] for p in before]) for f in ("execution_ms", "rows_removed_by_filter")}},
    "plan_after": {"node": after[0]["node"], "execution_ms": agg([p["execution_ms"] for p in after])},
    "build_seconds": agg([float((out / f"index-build-seconds-{k}.txt").read_text()) for k in R]),
    **{w: {f: agg([j(f"index-{w}-{k}.json")[f] for k in R]) for f in ("rps", "p50_ms", "p99_ms", "failed_pct")} for w in ("before", "after")},
}
res["nplus1"] = {np: {**{f: agg([j(f"nplus1-{np}-{k}.json")[f] for k in R]) for f in ("rps", "p50_ms", "p99_ms", "failed_pct")},
                      "db_queries_per_request": agg([j(f"nplus1-{np}-{k}.app.json")["db_queries"] / max(1, j(f"nplus1-{np}-{k}.json")["requests"]) for k in R])}
                 for np in ("0", "1")}
res["conns"] = {via: {c: {f: agg([bench(f"conns-{via}-{c}-{k}.txt")[f] for k in R]) for f in ("tps", "latency_avg_ms", "too_many_clients")}
                      for c in ("8", "32", "128", "512")} for via in ("direct", "bouncer")}
res["conns"]["default_limit_128"] = {f: agg([bench(f"conns-default-limit-{k}.txt")[f] for k in R]) for f in ("tps", "too_many_clients")}
lost = [j(f"lost-{k}.json") for k in R]
res["lost_update"] = {"expected": 5000, **{m: agg([x[m] for x in lost]) for m in ("read_then_write", "atomic_update")}}
skew = [j(f"skew-{k}.json") for k in R]
res["write_skew"] = {lvl: {f: agg([x[lvl][f] for x in skew]) for f in ("nobody_on_call", "refused_commits")} for lvl in skew[0]}
(out / "results.json").write_text(json.dumps(res, indent=1))
print(json.dumps(res, indent=1))
