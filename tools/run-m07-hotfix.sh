#!/usr/bin/env bash
# FIRST=4 tools/run-m07-hotfix.sh 6 adds runs 4-6 to an earlier 3-run result.
# Module 7.3 fix, N runs (default 3), three arms interleaved inside every run, 1,800 lookups/s for 30 s over 3 shards:
#   even   every code equally likely, no cache
#   hot    half of all requests ask for one code (HOT_PCT=50), no cache
#   cache  the same hot traffic, with the app's in-memory cache of hot codes (HOT_CACHE=1)
# The arm order rotates each run so no arm always runs first. Each arm: lab down, quiet gate, lab up, load with a CPU
# sample of every sdlab-* container (k6 included). Results: modules/m07-partitioning/results-hotfix/
set -euo pipefail
first=${FIRST:-1}; runs=${1:-3}; out=modules/m07-partitioning/results-hotfix; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m07-partitioning/compose.shards.yaml
arms=(even hot cache)
docker compose build app >/dev/null   # build once: code edited during a run must not slip into it
for k in $(seq "$first" "$runs"); do
  for i in 0 1 2; do
    arm=${arms[$(( (i + k - 1) % 3 ))]}
    case $arm in even) hot=0; cache=0;; hot) hot=50; cache=0;; cache) hot=50; cache=1;; esac
    tag="$arm-$k"
    docker compose down -v --remove-orphans >/dev/null 2>&1 || true
    tools/quiet-gate.sh 25 2 > "$out/$tag.gate"
    HOT_CACHE=$cache docker compose up -d --wait >/dev/null; sleep 3
    python3 tools/cpu-sampler.py "$out/$tag.cpu.tsv" 1 & cs=$!
    docker compose run --rm -e BASE=http://app:8080 -e HOT_PCT=$hot -e RESULT="$out/$tag.json" k6 run --quiet modules/m07-partitioning/hot.js >/dev/null 2>&1 || echo "k6 exit $? ($tag)" >&2
    kill $cs; wait $cs 2>/dev/null || true
    curl -s localhost:8080/stats/shards > "$out/$tag.shards.json"
    echo "run $k arm $arm done ($(cat "$out/$tag.gate"))"
  done
done
docker compose down -v --remove-orphans >/dev/null 2>&1
python3 tools/aggregate-m07-hotfix.py "$out" "$runs"
