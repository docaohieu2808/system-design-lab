#!/usr/bin/env bash
# What does the optional dashboard (compose.dash.yaml) cost, and does it move a result? N rounds (default 3), each
# round: the same 60 s open-model test (Module 0, 400 req/s on the preview-free short-link page) with the dashboard OFF,
# then ON. Writes modules/m00-the-lab/results-dash/*.json (+ .cpu.tsv) and results.json.
set -euo pipefail
runs=${1:-3}; out=modules/m00-the-lab/results-dash; mkdir -p "$out"
export UID GID=$(id -g)
one() {  # one <off|on> <round>
  local tag=$1-$2
  if [ "$1" = on ]; then export COMPOSE_FILE=compose.yaml:compose.dash.yaml; else export COMPOSE_FILE=compose.yaml; fi
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  tools/quiet-gate.sh 25 2 > "$out/$tag.gate"; docker compose up -d --wait >/dev/null; sleep 5
  python3 tools/cpu-sampler.py "$out/$tag.cpu.tsv" 1 & local cs=$!
  docker compose run --rm -e MODEL=open -e RATE=400 -e RESULT="/lab/$out/$tag.json" k6 \
    run --quiet modules/m00-the-lab/open-vs-closed.js >/dev/null 2>&1
  kill $cs; wait $cs 2>/dev/null || true
  echo "round $2 dashboard $1 done"
}
docker compose build app >/dev/null
for k in $(seq 1 "$runs"); do one off $k; one on $k; done
export COMPOSE_FILE=compose.yaml; docker compose down -v --remove-orphans >/dev/null 2>&1
python3 - "$out" "$runs" <<'PY'
import json, re, statistics as st, sys
from pathlib import Path
out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 3), "min": round(min(xs), 3), "max": round(max(xs), 3)}
def cores(tag, part):  # average cores of containers whose name contains part, over their sampled life
    first, last = {}, {}
    for l in (out / f"{tag}.cpu.tsv").read_text().splitlines():
        t, name, u, *_ = l.split("\t")
        if part in name and name not in ("HOST", "OTHER"):
            first.setdefault(name, (float(t), int(u))); last[name] = (float(t), int(u))
    return sum((last[n][1] - first[n][1]) / 1e6 / max(last[n][0] - first[n][0], 1) for n in first)
def host(tag):  # whole-machine busy share (%) over the 60 s the test ran: first vs last sample
    rows = [l.split("\t") for l in (out / f"{tag}.cpu.tsv").read_text().splitlines() if "\tHOST\t" in l]
    a, b = rows[0], rows[-1]; return 100 * (int(b[2]) - int(a[2])) / (int(b[4]) - int(a[4]))
res = {"runs": runs}
for mode in ("off", "on"):
    rows = []
    for k in range(1, runs + 1):
        t = f"{mode}-{k}"; r = json.loads((out / f"{t}.json").read_text())
        rows.append({"rps": r["rps"], "p99_ms": r["p99_ms"], "failed_pct": r["failed_pct"],
                     "app_cores": cores(t, "app"), "k6_cores": cores(t, "k6"),
                     "dashboard_cores": sum(cores(t, p) for p in ("prometheus", "grafana", "cstats")),
                     "host_busy_pct": host(t),
                     "background_busy_pct": float(re.search(r"background_busy_pct=(\d+)", (out / f"{t}.gate").read_text()).group(1))})
    res[mode] = {k_: agg([r[k_] for r in rows]) for k_ in rows[0]}
(out / "results.json").write_text(json.dumps(res, indent=1)); print(json.dumps(res, indent=1))
PY
