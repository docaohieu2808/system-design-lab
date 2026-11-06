"""Summarise the Module 5 variation runs into results.json.  python3 tools/aggregate-m05-deepen.py <dir> <runs>"""
import json
import re
import statistics as st
import sys
from pathlib import Path

out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}
R = range(1, runs + 1)
j = lambda name: json.loads((out / name).read_text())


def cores(tag, prefix):
    """Mean cores of the container whose name starts with prefix, over its sampled stretch."""
    rows = [(float(l.split("\t")[0]), int(l.split("\t")[2])) for l in (out / f"{tag}.cpu.tsv").read_text().splitlines() if l.split("\t")[1].startswith(prefix)]
    if len(rows) < 2:
        return 0.0
    # the app/db are busy only while the load runs: use the busiest-window mean (first to last sample where usage grows)
    busy = [i for i in range(1, len(rows)) if rows[i][1] > rows[i - 1][1] + 20000]
    if len(busy) < 2:
        return 0.0
    a, b = rows[busy[0] - 1], rows[busy[-1]]
    return (b[1] - a[1]) / 1e6 / (b[0] - a[0])


def gate(tag):
    return float((out / f"{tag}.gate").read_text().split()[0].split("=")[1])


def bench(tag):
    t = (out / f"{tag}.txt").read_text()
    tps, lat = re.search(r"tps = ([\d.]+)", t), re.search(r"latency average = ([\d.]+) ms", t)
    return {"tps": float(tps.group(1)) if tps else 0.0, "latency_avg_ms": float(lat.group(1)) if lat else 0.0,
            "too_many_clients": len(re.findall(r"too many clients", t))}


def per_arm(tags, rows_for, extra_cores):
    res = {}
    for tag in tags:
        rows = [rows_for(tag, k) for k in R]
        for k, r in zip(R, rows):
            r["background_busy_pct"] = gate(f"{tag}-{k}")
            for name, prefix in extra_cores.items():
                r[name] = cores(f"{tag}-{k}", prefix)
        res[tag] = {f: agg([r[f] for r in rows]) for f in rows[0]}
    return res


def k6row(tag, k):
    r = j(f"{tag}-{k}.json")
    return {f: r[f] for f in ("rps", "failed_pct", "dropped", "p50_ms", "p99_ms") if f in r}


def k6app(tag, k):
    r = k6row(tag, k)
    n = j(f"{tag}-{k}.json")["requests"]
    app = j(f"{tag}-{k}.app.json")
    return {**r, "db_queries_per_s": app["db_queries"] / 30, "db_queries_per_request": app["db_queries"] / max(1, n)}


res = {"runs": runs}
cpu = {"k6_cores": "sdlab-k6", "app_cores": "sdlab-app-1", "db_cores": "sdlab-db-1"}
res["index_no_index_by_rate"] = per_arm(["idx2", "idx5", "idx10"], k6row, cpu)
res["nplus1_rate_400"] = per_arm(["n1", "n0"], k6app, cpu)
res["pgbouncer_512_by_pool_size"] = per_arm(["p5", "p20", "p80"], lambda t, k: bench(f"{t}-{k}"), {"pgbench_cores": "sdlab-pgbench", "db_cores": "sdlab-db-1", "pgbouncer_cores": "sdlab-pgbouncer"})
res["lost_update_by_pool_max"] = per_arm(["l0", "l2", "l50"], lambda t, k: {f: v for f, v in j(f"{t}-{k}.json").items()}, {})
res["write_skew"] = per_arm(["skew"], lambda t, k: {f"{lvl}__{f}": v for lvl, d in j(f"{t}-{k}.json").items() for f, v in d.items() if f != "trials"}, {})
res["pgbench_8_clients"] = per_arm(["s8", "pr8"], lambda t, k: bench(f"{t}-{k}"), {"pgbench_cores": "sdlab-pgbench", "db_cores": "sdlab-db-1"})
(out / "results.json").write_text(json.dumps(res, indent=1))
print(json.dumps(res, indent=1))
