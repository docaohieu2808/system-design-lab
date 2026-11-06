#!/usr/bin/env bash
# Module 6, read scaling: how many reads per second does the stack sustain when reads go to the primary alone,
# and when they go to the replica? Reads only (GET /{code}, 302), the lesson 1.1 ladder, open model.
#   A  reads on the primary alone (READ_DATABASE_URL empty), app 0.5 core   (the lab's usual limits)
#   B  reads on the replica db2,                              app 0.5 core
#   C  reads on the replica db2,                              app 1.0 core   (the app is no longer the first limit)
#   D  reads on the primary alone,                            app 1.0 core   (C's control)
#   E  reads split at random between primary and replica,    app 1.0 core   (both databases do read work)
# Usage: tools/run-m06-reads.sh [runs] [arms...]   (default 3 runs, arms "A B C D E"). Arms are interleaved in every run.
# Each step: constant arrival rate, HOLD seconds, GAP quiet seconds. Output: modules/m06-replication/results-reads/
# <arm>-<run>.json (k6 per step), .cpu.tsv (per-second CPU counters, only sdlab-* and HOST lines), .gate (quiet gate).
set -euo pipefail
runs=${1:-3}; shift || true
arms=${*:-A B C D E}
out=modules/m06-replication/results-reads; mkdir -p "$out"
export UID GID=$(id -g)
export COMPOSE_FILE=compose.yaml:modules/m06-replication/compose.replica.yaml:modules/m06-replication/compose.reads.yaml
export APPLY_DELAY=0 RYW_SECONDS=0
other_max=${OTHER_MAX:-25}   # % of one core that all non-lab containers together may use during a run; more = discard and repeat
docker compose build app >/dev/null
run_arm() {  # run_arm <arm> <run>: one clean ladder; returns 1 if the run failed or another stack used the machine
  local a=$1 k=$2 rc=0 s steps
  unset APP_CPUS READ_SPREAD
  case $a in
    A) export APP_CPUS=0.5 READ_DATABASE_URL=; steps=${STEPS_HALF:-1750,2000,2250,2500,2750,3000,3500};;
    B) export APP_CPUS=0.5; unset READ_DATABASE_URL; steps=${STEPS_HALF:-1750,2000,2250,2500,2750,3000,3500};;
    C) export APP_CPUS=1.0; unset READ_DATABASE_URL; steps=${STEPS_ONE:-2000,2500,3000,3500,4000,5000,6000,7000,8000};;
    D) export APP_CPUS=1.0 READ_DATABASE_URL=; steps=${STEPS_ONE:-2000,2500,3000,3500,4000,5000,6000,7000,8000};;
    E) export APP_CPUS=1.0 READ_SPREAD=1; unset READ_DATABASE_URL; steps=${STEPS_ONE:-2000,2500,3000,3500,4000,5000,6000,7000,8000};;
  esac
  docker compose down -v >/dev/null 2>&1 || true
  tools/quiet-gate.sh 25 2 > "$out/$a-$k.gate"
  docker compose up -d --wait >/dev/null; sleep 3
  python3 tools/cpu-sampler.py "$out/$a-$k.cpu.raw" 1 & s=$!
  trap 'kill $s 2>/dev/null' EXIT      # never leave the sampler behind if k6 fails
  docker compose run --rm -e STEPS="$steps" -e HOLD=20 -e GAP=5 -e RESULT="$out/$a-$k.json" \
    k6 run --quiet modules/m01-one-server/find-the-ceiling.js >/dev/null 2> >(grep -v "Request Failed" | tail -n 5 > "$out/$a-$k.k6err") || rc=$?
  kill "$s"; wait "$s" 2>/dev/null || true; trap - EXIT
  other=$(awk '$2=="OTHER"{if(!f){f=$1;a=$3} l=$1;b=$3} END{printf "%d", 100*(b-a)/1e6/(l-f)}' "$out/$a-$k.cpu.raw")
  grep -v -P '\tOTHER\t' "$out/$a-$k.cpu.raw" > "$out/$a-$k.cpu.tsv"; rm -f "$out/$a-$k.cpu.raw"   # keep only sdlab-* and HOST
  [ "$rc" = 137 ] && echo "  k6 exit 137: OOMKilled=$(docker inspect -f '{{.State.OOMKilled}}' "$(docker ps -aq --filter name=sdlab-k6-run | head -1)" 2>/dev/null)"
  echo "run $k arm $a: k6 exit $rc, other containers $other% of a core, $(cat "$out/$a-$k.gate")"
  [ "$rc" = 0 ] && [ "$other" -le "$other_max" ]
}
for k in $(seq 1 "$runs"); do
  for a in $arms; do
    for try in 1 2 3 4 5; do
      run_arm "$a" "$k" && { echo "run $k arm $a done"; break; }
      echo "run $k arm $a discarded (attempt $try), repeating"; [ "$try" = 5 ] && { echo "run $k arm $a failed 5 times"; exit 1; }
    done
  done
done
docker compose down -v >/dev/null 2>&1
python3 tools/aggregate-m06-reads.py "$out" "$runs" $arms
