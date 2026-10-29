"""Summarise Module 9 runs into results.json.  python3 tools/aggregate-m09.py modules/m09-rate-limiting/results 3"""
import json
import statistics as st
import sys
from pathlib import Path

out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}
j = lambda n: [json.loads((out / f"{n}-{k}.json").read_text()) for k in range(1, runs + 1)]
res = {"runs": runs, "limit_per_s": 10}
for mode in ("local", "redis-bucket"):
    rows = j(f"shared-{mode}")
    res[f"shared_{mode}_allowed_per_s"] = agg([st.mean(r[p]["allowed_per_s"] for p in ("before", "during", "after")) for r in rows])
for mode in ("redis-window", "redis-bucket"):
    res[f"boundary_{mode}_allowed_in_200ms"] = agg([r["allowed_per_burst_pair"] for r in j(f"window-{mode}")])
for fail in ("open", "closed"):
    rows = j(f"outage-{fail}")
    res[f"outage_{fail}"] = {p: {f: agg([r[p][f] for r in rows]) for f in ("allowed_per_s", "refused_429", "errors_503")} for p in ("before", "during", "after")}
for cfg in ("left-insecure", "right-insecure", "left-default"):
    res[f"spoof_{cfg}_allowed_per_s"] = agg([st.mean(r[p]["allowed_per_s"] for p in ("before", "during", "after")) for r in j(f"spoof-{cfg}")])
(out / "results.json").write_text(json.dumps(res, indent=1))
print(json.dumps(res, indent=1))
