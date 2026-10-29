#!/usr/bin/env bash
# Module 9, four experiments, N runs each (default 3). About 25 minutes. Limit: 10 requests per second per client.
#   1 shared: 3 app copies; the limit kept in each copy's memory vs in Redis (token bucket)
#   2 window: bursts across a second boundary: fixed window (one counter per second) vs token bucket
#   3 outage: Redis paused for the middle 10 s of 30: fail open vs fail closed
#   4 spoof:  the client fakes X-Forwarded-For on every request: limit by the first address vs the last one
#             (with the proxy passing client headers on), and the proxy's default (it replaces them)
set -euo pipefail
runs=${1:-3}; out=modules/m09-rate-limiting/results; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m03-load-balancing/compose.lb.yaml:modules/m09-rate-limiting/compose.rl.yaml
fresh() { docker compose down -v --remove-orphans >/dev/null 2>&1 || true; docker compose up -d --wait --scale app=3 >/dev/null; sleep 3; }
k6() { docker compose run --rm "$@" k6 run --quiet modules/m09-rate-limiting/limited.js >/dev/null 2>&1; }
docker compose build app >/dev/null
for k in $(seq 1 "$runs"); do
  export RL_FAIL=open RL_CLIENT=xff-right XFF_INSECURE=false
  for mode in local redis-bucket; do export RL_MODE=$mode; fresh; k6 -e TEST=steady -e RESULT="$out/shared-$mode-$k.json"; echo "run $k shared $mode done"; done
  for mode in redis-window redis-bucket; do export RL_MODE=$mode; fresh; k6 -e TEST=boundary -e RESULT="$out/window-$mode-$k.json"; echo "run $k window $mode done"; done
  export RL_MODE=redis-bucket
  for fail in open closed; do
    export RL_FAIL=$fail; fresh
    ( sleep 12; docker compose pause redis >/dev/null; sleep 10; docker compose unpause redis >/dev/null ) & ev=$!
    k6 -e TEST=steady -e RESULT="$out/outage-$fail-$k.json"; wait $ev; echo "run $k outage $fail done"
  done
  export RL_FAIL=open
  for cfg in left-insecure right-insecure left-default; do
    export RL_CLIENT=xff-${cfg%%-*} XFF_INSECURE=$([ ${cfg#*-} = insecure ] && echo true || echo false); fresh
    k6 -e TEST=steady -e SPOOF=1 -e RESULT="$out/spoof-$cfg-$k.json"; echo "run $k spoof $cfg done"
  done
done
docker compose down -v --remove-orphans >/dev/null 2>&1
python3 tools/aggregate-m09.py "$out" "$runs"
