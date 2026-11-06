#!/usr/bin/env bash
# Module 1 / 2 variations of the ceiling test (modules/m01-one-server/find-the-ceiling.js), N runs (default 3), arms
# interleaved inside every run (order rotates each run). Each arm is the whole 10-step test on a fresh stack.
#   base     the lab as it is: app half a core, k6 up to 2 cores
#   k6half   k6 limited to half a core (K6_CPUS=0.5)
#   app1     the app gets a whole core (modules/m01-one-server/compose.app1core.yaml)
# A CPU sample of every sdlab-* container (k6 included) is kept per arm. Results: modules/m01-one-server/results-variations/
set -euo pipefail
runs=${1:-3}; out=modules/m01-one-server/results-variations; mkdir -p "$out"
export UID GID=$(id -g)
arms=(base k6half app1)
docker compose build app >/dev/null
for k in $(seq 1 "$runs"); do
  for i in 0 1 2; do
    arm=${arms[$(( (i + k - 1) % 3 ))]}
    export K6_CPUS=2.0 COMPOSE_FILE=compose.yaml:modules/m01-one-server/compose.k6mem.yaml
    case $arm in k6half) K6_CPUS=0.5;; app1) COMPOSE_FILE=$COMPOSE_FILE:modules/m01-one-server/compose.app1core.yaml;; esac
    tag="$arm-$k"
    [ -n "${ONLY:-}" ] && [[ " $ONLY " != *" $tag "* ]] && continue   # ONLY="base-2 base-3" repeats just those arms
    docker compose down -v --remove-orphans >/dev/null 2>&1 || true
    tools/quiet-gate.sh 25 2 > "$out/$tag.gate"
    docker compose up -d --wait >/dev/null; sleep 3
    python3 tools/cpu-sampler.py "$out/$tag.cpu.tsv" 1 & cs=$!
    docker compose run --rm -e RESULT="$out/$tag.json" k6 run --quiet modules/m01-one-server/find-the-ceiling.js >/dev/null 2>&1 || echo "k6 exit $? ($tag)" >&2
    kill $cs; wait $cs 2>/dev/null || true
    echo "run $k arm $arm done ($(cat "$out/$tag.gate"))"
  done
done
docker compose down -v --remove-orphans >/dev/null 2>&1
python3 tools/aggregate-m01-variations.py "$out" "$runs"
