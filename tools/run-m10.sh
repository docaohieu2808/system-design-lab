#!/usr/bin/env bash
# Module 10, five experiments, N runs each (default 3). About 25 minutes.
#   1 inline: 40 creates/s, each with 200 ms of side work: done inside the request vs put on a queue
#   2 lag:    queued, drained by 1 worker vs 16 workers for 40 s: how long jobs wait, how much is left over
#   3 charges: 1,000 payment jobs, the worker crashes after charging 10% of the time: without vs with idempotency key
#   4 poison: 200 good jobs behind one that always fails: retry forever vs dead-letter after 3 tries
#   5 storm:  the app is frozen for the middle 10 s; clients retry at once vs with exponential backoff and jitter
set -euo pipefail
runs=${1:-3}; out=modules/m10-async/results; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m10-async/compose.queue.yaml
fresh() { docker compose down -v --remove-orphans >/dev/null 2>&1 || true; docker compose up -d --wait >/dev/null; sleep 2; }
create() { docker compose run --rm "$@" k6 run --quiet modules/m10-async/create.js >/dev/null 2>&1; }
docker compose build app >/dev/null
for k in $(seq 1 "$runs"); do
  for q in 0 1; do export QUEUE=$q SIDE_WORK_MS=200; fresh; create -e RESULT="$out/inline-$q-$k.json"; echo "run $k inline queue=$q done"; done
  for w in 1 16; do
    export QUEUE=1; fresh
    docker compose run --rm --no-deps -e WORKERS=$w -e WORKER_SECONDS=40 app drill worker > "$out/lag-$w-$k.json" 2>/dev/null & wk=$!
    create -e RESULT="$out/lag-$w-$k.k6.json"; wait $wk; echo "run $k lag workers=$w done"
  done
  for idem in 0 1; do fresh; docker compose run --rm --no-deps -e CRASH_PCT=10 -e IDEMPOTENT=$idem app drill charges > "$out/charges-$idem-$k.json" 2>/dev/null; echo "run $k charges idem=$idem done"; done
  for dlq in 0 3; do fresh; docker compose run --rm --no-deps -e DLQ_AFTER=$dlq app drill poison > "$out/poison-$dlq-$k.json" 2>/dev/null; echo "run $k poison dlq=$dlq done"; done
  export QUEUE=0 SIDE_WORK_MS=0
  for r in immediate backoff; do
    fresh; ( sleep 12; docker compose pause app >/dev/null; sleep 10; docker compose unpause app >/dev/null ) & ev=$!
    create -e RETRY=$r -e RESULT="$out/storm-$r-$k.json"; wait $ev; echo "run $k storm $r done"
  done
done
docker compose down -v --remove-orphans >/dev/null 2>&1
python3 tools/aggregate-m10.py "$out" "$runs"
