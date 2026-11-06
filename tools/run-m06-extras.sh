#!/usr/bin/env bash
# Module 6 variations, N runs each (default 3), arms interleaved in every run, fresh stack and quiet gate before each:
#   lag50     create-then-read at 50/s for 30 s, replica applies changes 50 ms late, no read-your-writes
#   edge      replica 1.5 s late, read-your-writes window 1 s, the open waits 1.2 s after the create (window < wait < lag)
#   promote2  failover as in run-m06.sh (async), but the replica is promoted 2 s after the kill instead of 5 s
# Output: modules/m06-replication/results-extras/ and results.json (via tools/aggregate-m06-extras.py).
set -euo pipefail
runs=${1:-3}; out=modules/m06-replication/results-extras; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m06-replication/compose.replica.yaml
fresh() { docker compose down -v >/dev/null 2>&1 || true; tools/quiet-gate.sh 25 2 > "$out/$1.gate"; docker compose up -d --wait >/dev/null; sleep 3; }
docker compose build app >/dev/null
for k in $(seq 1 "$runs"); do
  export APPLY_DELAY=50ms RYW_SECONDS=0; fresh "lag50-$k"
  docker compose run --rm -e BASE=http://app:8080 -e RESULT="$out/lag50-$k.json" k6 run --quiet modules/m06-replication/ryw.js >/dev/null 2>&1
  echo "run $k lag50 done"
  export APPLY_DELAY=1500ms RYW_SECONDS=1; fresh "edge-$k"
  docker compose run --rm -e BASE=http://app:8080 -e READ_DELAY=1.2 -e RESULT="$out/edge-$k.json" k6 run --quiet modules/m06-replication/ryw.js >/dev/null 2>&1
  echo "run $k edge done"
  export APPLY_DELAY=0 RYW_SECONDS=0; fresh "promote2-$k"
  ( sleep 15; date +%s.%N > "$out/promote2-$k.killed"; docker kill sdlab-db-1 >/dev/null
    sleep 2; docker compose exec -T db2 psql -U postgres -qAt -c "SELECT pg_promote()" >/dev/null ) & ev=$!
  start=$(date +%s.%N)
  docker compose run --rm --no-deps -e WRITER_RATE=100 -e WRITER_SECONDS=40 app drill failover-writer > "$out/promote2-$k.jsonl" 2>/dev/null || true
  wait $ev
  echo "$start" > "$out/promote2-$k.start"
  docker compose exec -T db2 psql -U postgres -d shortener -qAt -c "SELECT code FROM links WHERE code LIKE 'fo-%'" > "$out/promote2-$k.present"
  echo "run $k promote2 done"
done
docker compose down -v >/dev/null 2>&1
python3 tools/aggregate-m06-extras.py "$out" "$runs"
