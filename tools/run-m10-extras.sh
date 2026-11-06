#!/usr/bin/env bash
# Module 10, extra variations for lessons 10.1-10.5, N runs each (default 3), the arms of each experiment interleaved in every run.
#   side400   side work 400 ms instead of 200 ms: inline vs queued, 40 creates/s
#   workers   lag drill with 1, 4, 8, 16 workers (1 and 16 repeat the main run so the arms share the machine's conditions)
#   crash30   payment worker that crashes after charging 30% of the time: no key vs idempotency key
#   dlq30     poison message parked after 3 tries vs after 30 tries
#   storm2    retry storm with only 2 retries: retry at once vs backoff with jitter
# Output: modules/m10-async/results-extras/ and results.json. Run it inside flock.
set -euo pipefail
runs=${1:-3}; out=modules/m10-async/results-extras; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m10-async/compose.queue.yaml
fresh() {  # fresh <tag>: lab down, quiet gate (reading saved), lab up
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  tools/quiet-gate.sh 25 2 > "$out/$1.gate"; docker compose up -d --wait >/dev/null; sleep 2
}
create() { docker compose run --rm "$@" k6 run --quiet modules/m10-async/create.js >/dev/null 2>&1; }
docker compose build app >/dev/null
for k in $(seq 1 "$runs"); do
  for q in 0 1; do t=side400-$q-$k; export QUEUE=$q SIDE_WORK_MS=400; fresh $t; create -e RESULT="$out/$t.json"; echo "run $k side400 queue=$q done"; done
  export QUEUE=1 SIDE_WORK_MS=200
  for w in 1 4 8 16; do
    t=workers-$w-$k; fresh $t
    docker compose run --rm --no-deps -e WORKERS=$w -e WORKER_SECONDS=40 app drill worker > "$out/$t.json" 2>/dev/null & wk=$!
    create -e RESULT="$out/$t.k6.json"; wait $wk; echo "run $k workers=$w done"
  done
  for idem in 0 1; do t=crash30-$idem-$k; fresh $t; docker compose run --rm --no-deps -e CRASH_PCT=30 -e IDEMPOTENT=$idem app drill charges > "$out/$t.json" 2>/dev/null; echo "run $k crash30 idem=$idem done"; done
  for dlq in 3 30; do t=dlq-$dlq-$k; fresh $t; docker compose run --rm --no-deps -e DLQ_AFTER=$dlq app drill poison > "$out/$t.json" 2>/dev/null; echo "run $k dlq=$dlq done"; done
  export QUEUE=0 SIDE_WORK_MS=0
  arms=(immediate backoff)
  for n in 0 1; do
    r=${arms[$(( (n + k - 1) % 2 ))]}; t=storm2-$r-$k; fresh $t
    ( sleep 12; date +%s.%N > "$out/$t.stopped"; docker compose stop app >/dev/null; sleep 10; docker compose start app >/dev/null; date +%s.%N > "$out/$t.started" ) & ev=$!
    create -e RETRY=$r -e RETRIES=2 -e RESULT="$out/$t.json" || true
    wait $ev; echo "run $k storm2 $r done"
  done
done
docker compose down -v --remove-orphans >/dev/null 2>&1
python3 tools/aggregate-m10-extras.py "$out" "$runs"
