#!/usr/bin/env bash
# Run one module's k6 experiment N times on a fresh stack and record CPU of every container.
#   tools/run-experiment.sh modules/m01-one-server/find-the-ceiling.js 3
# Writes <module>/results/run-K.json (k6 per-step numbers) and run-K.cpu.tsv (docker stats samples),
# then <module>/results/results.json (aggregate) via tools/aggregate.py.
set -euo pipefail
script=$1; runs=${2:-3}; shift 2 || true
mod=$(dirname "$script"); out=${OUT:-$mod/results}; mkdir -p "$out"
export UID GID=$(id -g)
for k in $(seq 1 "$runs"); do
  docker compose down -v >/dev/null 2>&1 || true
  docker compose up -d --build --wait ${SCALE:+--scale app=$SCALE} >/dev/null   # SCALE=N: N app copies (Module 3)
  sleep 3                                   # let Postgres finish warming its cache
  # only the lab's own containers: the host may run other services, and their names do not belong in the results
  ( while :; do docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}' | grep '^sdlab-' | sed "s/^/$(date +%s)\t/"; sleep 2; done ) > "$out/run-$k.cpu.tsv" &
  sampler=$!
  docker compose run --rm -e RESULT="$out/run-$k.json" "$@" k6 run --quiet "$script" >/dev/null
  kill $sampler; wait $sampler 2>/dev/null || true
  echo "run $k done"
done
docker compose down -v >/dev/null 2>&1
python3 tools/aggregate.py "$out" "$runs"
