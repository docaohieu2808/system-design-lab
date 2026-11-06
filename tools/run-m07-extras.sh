#!/usr/bin/env bash
# Module 7 variations, N runs (default 3), arms interleaved inside every run (order rotates each run):
#   even    even traffic, 1,800 lookups/s (reference for the others)
#   r600    even traffic at 600 lookups/s
#   hot20   20% of requests ask for one code, 1,800 lookups/s
# FIRST=4 tools/run-m07-extras.sh 6 adds runs 4-6 to an earlier 3-run result (the arm order keeps rotating).
# plus the rehash drill with 10 points per shard (VNODES=10; deterministic, one run). Results: results-extras/
set -euo pipefail
first=${FIRST:-1}; runs=${1:-3}; out=modules/m07-partitioning/results-extras; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m07-partitioning/compose.shards.yaml HOT_CACHE=0
arms=(even r600 hot20)
docker compose build app >/dev/null
docker compose down -v --remove-orphans >/dev/null 2>&1 || true
[ "$first" = 1 ] && docker compose run --rm --no-deps -e VNODES=10 app drill rehash > "$out/rehash-vnodes10.json"
for k in $(seq "$first" "$runs"); do
  for i in 0 1 2; do
    arm=${arms[$(( (i + k - 1) % 3 ))]}
    case $arm in even) hot=0; rate=1800;; r600) hot=0; rate=600;; hot20) hot=20; rate=1800;; esac
    tag="$arm-$k"
    docker compose down -v --remove-orphans >/dev/null 2>&1 || true
    tools/quiet-gate.sh 25 2 > "$out/$tag.gate"
    docker compose up -d --wait >/dev/null; sleep 3
    python3 tools/cpu-sampler.py "$out/$tag.cpu.tsv" 1 & cs=$!
    docker compose run --rm -e BASE=http://app:8080 -e HOT_PCT=$hot -e RATE=$rate -e RESULT="$out/$tag.json" k6 run --quiet modules/m07-partitioning/hot.js >/dev/null 2>&1 || echo "k6 exit $? ($tag)" >&2
    kill $cs; wait $cs 2>/dev/null || true
    curl -s localhost:8080/stats/shards > "$out/$tag.shards.json"
    echo "run $k arm $arm done ($(cat "$out/$tag.gate"))"
  done
done
docker compose down -v --remove-orphans >/dev/null 2>&1
python3 tools/aggregate-m07-hotfix.py "$out" "$runs" even,r600,hot20
