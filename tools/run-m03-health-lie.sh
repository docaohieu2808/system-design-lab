#!/usr/bin/env bash
# Module 3, lesson 3.3: health checks that lie. 3 copies (2 good + 1 that loses its database halfway), a steady
# 400 pages/s for 60 s, three ways: no health check, a shallow check (/livez: process alive), a deep check (/healthz:
# touches the database). N runs each (default 3). About 10 minutes. Output: modules/m03-load-balancing/results-health/
set -euo pipefail
runs=${1:-3}; out=modules/m03-load-balancing/results-health; mkdir -p "$out"
export UID GID=$(id -g) LB_STRATEGY=wrr
M=modules/m03-load-balancing
BASE=compose.yaml:$M/compose.lb.yaml:$M/compose.dbloss.yaml
COMPOSE_FILE=$BASE docker compose build app >/dev/null
for k in $(seq 1 "$runs"); do
  for mode in none shallow deep; do
    case $mode in none) export COMPOSE_FILE=$BASE; unset HC_PATH;;
      shallow) export COMPOSE_FILE=$BASE:$M/compose.health-path.yaml HC_PATH=/livez;;
      deep) export COMPOSE_FILE=$BASE:$M/compose.health-path.yaml HC_PATH=/healthz;; esac
    docker compose down -v >/dev/null 2>&1 || true
    tools/quiet-gate.sh 25 2 > "$out/$mode-$k.gate"
    docker compose up -d --wait --scale app=2 >/dev/null; sleep 3
    ( sleep 32; docker network disconnect sdlab_dbnet sdlab-appbad-1 >/dev/null ) & ev=$!
    docker compose run --rm -e RATE=400 -e HALF=30 -e RESULT="$out/$mode-$k.json" k6 run --quiet $M/steady.js >/dev/null
    wait $ev
    echo "run $k $mode done ($(cat "$out/$mode-$k.gate"))"
  done
done
docker compose down -v >/dev/null 2>&1
python3 - "$out" "$runs" <<'PY'
import json, statistics as st, sys
from pathlib import Path
out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": min(xs), "max": max(xs)}
res = {"runs": runs, "rate": 400}
for mode in ("none", "shallow", "deep"):
    data = [json.loads((out / f"{mode}-{k}.json").read_text()) for k in range(1, runs + 1)]
    res[mode] = {p: {f: agg([d[p][f] for d in data]) for f in data[0][p]} for p in ("before", "after")}
    res[mode]["background_busy_pct"] = [int(dict(x.split("=") for x in (out / f"{mode}-{k}.gate").read_text().split()[:2])["background_busy_pct"]) for k in range(1, runs + 1)]
(out / "results.json").write_text(json.dumps(res, indent=1))
for mode in ("none", "shallow", "deep"):
    r = res[mode]; print(mode, {p: (r[p]["failed"]["mean"], r[p]["p99_ms"]["mean"]) for p in ("before", "after")})
PY
