#!/usr/bin/env bash
# Module 10, experiment 5 only (retry storm), N runs (default 3); then re-aggregates results.json.
# Three retry arms, interleaved inside every run (the order rotates from run to run), so they share the machine's conditions:
#   immediate         retry at once, up to 5 times
#   backoff           wait 200 ms, 400 ms, ... times a random 0.5-1.5 (jitter)
#   backoff-nojitter  the same waits, exactly (no random factor)
# The app is stopped from 12 s to about 22 s of a 30 s run of 40 creates/s. Besides the k6 result, each run saves the quiet-gate
# reading, the outage's wall-clock start/end, and a CPU sample of every sdlab container (k6 included).
set -euo pipefail
runs=${1:-3}; out=modules/m10-async/results
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m10-async/compose.queue.yaml QUEUE=0 SIDE_WORK_MS=0
arms=(immediate backoff backoff-nojitter)
fresh() {  # fresh <tag>: lab down, wait for a quiet machine (the background it saw is saved next to the result), lab up
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  tools/quiet-gate.sh 25 2 > "$out/$1.gate"; docker compose up -d --wait >/dev/null; sleep 2
}
docker compose build app >/dev/null
for k in $(seq 1 "$runs"); do
  for n in 0 1 2; do
    r=${arms[$(( (n + k - 1) % 3 ))]}; tag="storm-$r-$k"
    fresh "$tag"
    ( sleep 12; date +%s.%N > "$out/$tag.stopped"; docker compose stop app >/dev/null; sleep 10; docker compose start app >/dev/null; date +%s.%N > "$out/$tag.started" ) & ev=$!
    python3 tools/cpu-sampler.py "$out/$tag.cpu.tsv" 1 & cs=$!
    set +e
    docker compose run --name sdlab-k6-m10 -e RETRY=$r -e RESULT="$out/$tag.json" k6 run --quiet modules/m10-async/create.js >/dev/null 2>&1
    rc=$?; set -e
    echo "$rc" > "$out/$tag.rc"
    if [ $rc -ne 0 ]; then echo "k6 exit $rc, OOMKilled=$(docker inspect -f '{{.State.OOMKilled}}' sdlab-k6-m10 2>/dev/null)" >&2; fi
    docker rm -f sdlab-k6-m10 >/dev/null 2>&1 || true
    kill $cs 2>/dev/null || true; wait $cs 2>/dev/null || true
    wait $ev; echo "run $k storm $r done (k6 exit $rc)"
    if [ $rc -ne 0 ]; then docker compose down -v --remove-orphans >/dev/null 2>&1; echo "stopping: a run with k6 exit $rc is not a measurement" >&2; exit 1; fi
  done
done
docker compose down -v --remove-orphans >/dev/null 2>&1
python3 tools/aggregate-m10.py "$out" "$runs"
