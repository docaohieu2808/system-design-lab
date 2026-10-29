"""Summarise Module 6 runs into results.json.

    python3 tools/aggregate-m06.py modules/m06-replication/results 3
"""
import json
import statistics as st
import sys
from pathlib import Path

out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}
R = range(1, runs + 1)
res = {"runs": runs, "ryw": {}, "failover": {}}
for cfg in ("nolag", "lag", "lag-ryw"):
    rows = [json.loads((out / f"ryw-{cfg}-{k}.json").read_text()) for k in R]
    res["ryw"][cfg] = {f: agg([r[f] for r in rows]) for f in ("found", "missing", "missing_pct", "failed")}
for mode in ("async", "sync"):
    rows = []
    for k in R:
        att = [json.loads(l) for l in (out / f"failover-{mode}-{k}.jsonl").read_text().splitlines() if l.startswith("{")]
        killed = float((out / f"failover-{mode}-{k}.killed").read_text()) - float((out / f"failover-{mode}-{k}.start").read_text())
        present = set((out / f"failover-{mode}-{k}.present").read_text().split())
        acked = [a for a in att if a["ok"]]
        lost = [a for a in acked if a["code"] not in present]
        before = [a["t"] for a in att if a["ok"] and a["t"] < killed + 0.5]
        after = [a["t"] for a in att if a["ok"] and a["t"] > (before[-1] if before else 0) + 0.5]
        rows.append({"rto_s": (after[0] - before[-1]) if before and after else -1, "acked": len(acked),
                     "lost": len(lost), "failed_attempts": sum(1 for a in att if not a["ok"])})
    res["failover"][mode] = {f: agg([r[f] for r in rows]) for f in rows[0]}
(out / "results.json").write_text(json.dumps(res, indent=1))
print(json.dumps(res, indent=1))
