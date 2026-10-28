"""Aggregate repeated k6 runs into one results.json: mean and spread per step, plus peak CPU per container.

    python3 tools/aggregate.py modules/m01-one-server/results 3
"""
import json
import statistics as st
import sys
from collections import defaultdict
from pathlib import Path

out, runs = Path(sys.argv[1]), int(sys.argv[2])
data = [json.loads((out / f"run-{k}.json").read_text()) for k in range(1, runs + 1)]
fields = [f for f in data[0]["steps"][0] if f != "asked_rps"]
steps = []
for i, s in enumerate(data[0]["steps"]):
    row = {"asked_rps": s["asked_rps"]}
    for f in fields:
        vals = [d["steps"][i][f] for d in data]
        row[f] = {"mean": round(st.mean(vals), 2), "min": min(vals), "max": max(vals),
                  "spread_pct": round(100 * (max(vals) - min(vals)) / st.mean(vals), 1) if st.mean(vals) else 0.0}
    steps.append(row)
peak = defaultdict(float)                     # highest CPU% seen per container (100% = one full core)
for k in range(1, runs + 1):
    for line in (out / f"run-{k}.cpu.tsv").read_text().splitlines():
        try:
            _, name, cpu = line.split("\t")
            if not name.startswith("sdlab-"):
                continue                      # other containers on the host are not part of the lab
            key = "k6" if "-k6-run-" in name else name
            peak[key] = max(peak[key], float(cpu.rstrip("%")))
        except ValueError:
            continue
json.dump({"runs": runs, "hold_s": data[0]["hold_s"], "peak_cpu_pct": dict(peak), "steps": steps},
          open(out / "results.json", "w"), indent=1)
print(f"{out}/results.json: {len(steps)} steps x {runs} runs; peak CPU {dict(peak)}")
