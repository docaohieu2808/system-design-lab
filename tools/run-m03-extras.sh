#!/usr/bin/env bash
# Module 3, five extra experiments for lessons 3.1-3.4, N runs each (default 3), the arms of each interleaved inside every run:
#   split    4 copies at 0.25 core vs 2 copies at 0.5 core: step test 150 -> 1,350 pages/s (ceiling, p99 at 450)
#   kill400  3 copies, steady 400 pages/s, one copy killed at 32 s
#   hc       freeze one of 3 copies at 400 pages/s, Traefik health check every 1 s vs every 5 s
#   twoslow  3 copies, two squeezed to 0.08 core, 400 pages/s, wrr vs p2c
#   slow1    ONE copy at 0.08 core: step test 30 -> 180 pages/s, its real ceiling
# Output: modules/m03-load-balancing/results-extras/ (per-arm json, .gate) and results.json. Run it inside flock.
set -euo pipefail
runs=${1:-3}; out=modules/m03-load-balancing/results-extras; mkdir -p "$out"
export UID GID=$(id -g) LB_STRATEGY=wrr
M=modules/m03-load-balancing
LB=compose.yaml:$M/compose.lb.yaml:$M/compose.cause.yaml   # cause overlay only gives k6 3 GB (defaults change nothing else)
HALF=30
fresh() {  # fresh <tag> <copies>: down, quiet gate (reading saved), up
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  tools/quiet-gate.sh 25 2 > "$out/$1.gate"; docker compose up -d --wait --scale app="$2" >/dev/null; sleep 3
}
steady() {  # steady <rate> <result> <event command at 32 s>
  ( sleep $((HALF + 2)); eval "$3" ) & local ev=$!
  docker compose run --rm -e RATE="$1" -e HALF=$HALF -e RESULT="$2" k6 run --quiet $M/steady.js >/dev/null 2>&1 || true
  wait $ev
}
steps() {  # steps <result> <step list>
  docker compose run --rm -e PREFIX=page/ -e EXPECT=200 -e STEPS="$2" -e HOLD=15 -e GAP=5 -e RESULT="$1" k6 run --quiet modules/m01-one-server/find-the-ceiling.js >/dev/null 2>&1 || true
}
arm() {  # arm <name> <run>
  local n=$1 k=$2 t=$1-$2
  export COMPOSE_FILE=$LB; unset APP_CPUS HC_INTERVAL; export LB_STRATEGY=wrr
  case $n in
    split4) fresh $t 4; steps "$out/$t.json" 150,300,450,600,750,900,1050,1200,1350;;
    split2) export APP_CPUS=0.5; fresh $t 2; steps "$out/$t.json" 150,300,450,600,750,900,1050,1200,1350;;
    kill400) fresh $t 3; steady 400 "$out/$t.json" "docker kill sdlab-app-2 >/dev/null";;
    hc1) export COMPOSE_FILE=$LB:$M/compose.health5.yaml HC_INTERVAL=1s; fresh $t 3; steady 400 "$out/$t.json" "docker pause sdlab-app-2 >/dev/null"; docker unpause sdlab-app-2 >/dev/null || true;;
    hc5) export COMPOSE_FILE=$LB:$M/compose.health5.yaml HC_INTERVAL=5s; fresh $t 3; steady 400 "$out/$t.json" "docker pause sdlab-app-2 >/dev/null"; docker unpause sdlab-app-2 >/dev/null || true;;
    twoslow-wrr|twoslow-p2c) export LB_STRATEGY=${n#twoslow-}; fresh $t 3; docker update --cpus 0.08 sdlab-app-2 sdlab-app-3 >/dev/null; steady 400 "$out/$t.json" "true";;
    slow1) export APP_CPUS=0.08; fresh $t 1; steps "$out/$t.json" 30,60,90,120,150,180;;
  esac
  [ -s "$out/$t.json" ] || { echo "arm $t produced no result" >&2; exit 1; }
  echo "run $k $n done ($(cat $out/$t.gate))"
}
COMPOSE_FILE=$LB docker compose build app >/dev/null
for k in $(seq 1 "$runs"); do
  for n in split4 split2 kill400 hc1 hc5 twoslow-wrr twoslow-p2c slow1; do arm $n $k; done
done
docker compose down -v --remove-orphans >/dev/null 2>&1
python3 - "$out" "$runs" <<'PY'
import json, statistics as st, sys
from pathlib import Path
out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": min(xs), "max": max(xs)}
L = lambda n: [json.loads((out / f"{n}-{k}.json").read_text()) for k in range(1, runs + 1)]
res = {"runs": runs}
for n in ("split4", "split2", "slow1"):
    d = L(n)
    res[n] = {"ceiling_rps": agg([max(s["succeeded_rps"] for s in j["steps"]) for j in d]),
              "steps": {str(a): {"succeeded_rps": agg([next(s for s in j["steps"] if s["asked_rps"] == a)["succeeded_rps"] for j in d]),
                                 "p99_ms": agg([next(s for s in j["steps"] if s["asked_rps"] == a)["p99_ms"] for j in d])}
                        for a in [s["asked_rps"] for s in d[0]["steps"]]}}
for n in ("kill400", "hc1", "hc5", "twoslow-wrr", "twoslow-p2c"):
    d = L(n)
    res[n] = {p: {f: agg([j[p][f] for j in d]) for f in ("failed", "p99_ms")} for p in ("before", "after")}
(out / "results.json").write_text(json.dumps(res, indent=1))
for n, r in res.items():
    if n != "runs": print(n, json.dumps(r)[:600])
PY
