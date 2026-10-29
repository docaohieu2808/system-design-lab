#!/usr/bin/env bash
# Module 10, experiment 5 only (retry storm), N runs (default 3); then re-aggregates results.json.
set -euo pipefail
runs=${1:-3}; out=modules/m10-async/results
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m10-async/compose.queue.yaml QUEUE=0 SIDE_WORK_MS=0
fresh() { docker compose down -v --remove-orphans >/dev/null 2>&1 || true; docker compose up -d --wait >/dev/null; sleep 2; }
docker compose build app >/dev/null
for k in $(seq 1 "$runs"); do
  for r in immediate backoff; do
    fresh; ( sleep 12; docker compose stop app >/dev/null; sleep 10; docker compose start app >/dev/null ) & ev=$!
    docker compose run --rm -e RETRY=$r -e RESULT="$out/storm-$r-$k.json" k6 run --quiet modules/m10-async/create.js >/dev/null 2>&1
    wait $ev; echo "run $k storm $r done"
  done
done
docker compose down -v --remove-orphans >/dev/null 2>&1
python3 tools/aggregate-m10.py "$out" "$runs"
