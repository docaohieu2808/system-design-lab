"""Summarise tools/run-m10-extras.sh into results.json (mean, min, max over runs).  python3 tools/aggregate-m10-extras.py <dir> <runs>"""
import json
import re
import statistics as st
import sys
from pathlib import Path

out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}
def J(name):  # k6 results are pretty-printed json, drill output is one json line
    text = (out / name).read_text().strip()
    try:
        return json.loads(text)
    except ValueError:
        return json.loads(text.splitlines()[-1])
gate = lambda tag: float(re.search(r"background_busy_pct=(\d+)", (out / f"{tag}.gate").read_text()).group(1))
res = {"runs": runs}
for q in (0, 1):
    rows = [J(f"side400-{q}-{k}.json") for k in range(1, runs + 1)]
    res[f"side400_queue{q}"] = {f: agg([r[f] for r in rows]) for f in ("create_p50_ms", "create_p99_ms")}
for w in (1, 4, 8, 16):
    rows = [J(f"workers-{w}-{k}.json") for k in range(1, runs + 1)]
    res[f"workers_{w}"] = {"done": agg([r["done"] for r in rows]), "pending": agg([r["pending"] for r in rows]),
                           "wait_p50_ms": agg([r["wait_ms"]["p50"] for r in rows]), "wait_p99_ms": agg([r["wait_ms"]["p99"] for r in rows])}
for i in (0, 1):
    rows = [J(f"crash30-{i}-{k}.json") for k in range(1, runs + 1)]
    res[f"crash30_idem{i}"] = {f: agg([r[f] for r in rows]) for f in ("charges", "crashes", "double_charges")}
for d in (3, 30):
    rows = [J(f"dlq-{d}-{k}.json") for k in range(1, runs + 1)]
    res[f"dlq_{d}"] = {f: agg([r[f] for r in rows]) for f in ("good_done_in_10s", "poison_attempts", "parked_in_dlq")}
for arm in ("immediate", "backoff"):
    rows = []
    for k in range(1, runs + 1):
        t = f"storm2-{arm}-{k}"
        r = J(f"{t}.json")
        t0 = r["test_started_ms"] / 1000
        back = int(float((out / f"{t}.started").read_text()) - t0) + 1
        per = r["per_second_attempts"]
        rows.append({"during_attempts": r["during"]["attempts"], "after_attempts": r["after"]["attempts"],
                     "gave_up_total": sum(r[p]["gave_up"] for p in ("before", "during", "after")),
                     "created_after": r["after"]["created"], "peak_1s_after_return": max(per[back:]), "peak_1s_overall": max(per),
                     "create_p99_ms": r["create_p99_ms"], "background_busy_pct": gate(t)})
    res[f"storm2_{arm}"] = {f: agg([x[f] for x in rows]) for f in rows[0]}
(out / "results.json").write_text(json.dumps(res, indent=1))
print(json.dumps(res, indent=1))
