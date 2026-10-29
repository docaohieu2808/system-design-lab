#!/usr/bin/env bash
# Module 6, two experiments, N runs each (default 3). About 25 minutes.
#   1 ryw:      create-then-read at 50 per second for 30 s, reads from the replica:
#               no added lag / replica applies changes 500 ms late / 500 ms late + read-your-writes (2 s)
#   2 failover: a writer creates 100 links per second for 40 s; the primary is killed at 15 s and the replica promoted
#               5 s later; async replication vs synchronous (remote_apply). RTO = time without successful writes,
#               RPO = writes the client was told succeeded that the promoted replica does not have.
# Writes modules/m06-replication/results/*.json(l) and results.json.
set -euo pipefail
runs=${1:-3}; out=modules/m06-replication/results; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m06-replication/compose.replica.yaml
fresh() { docker compose down -v >/dev/null 2>&1 || true; docker compose up -d --wait >/dev/null; sleep 3; }
docker compose build app >/dev/null
for k in $(seq 1 "$runs"); do
  for cfg in nolag lag lag-ryw; do
    export APPLY_DELAY=$([ $cfg = nolag ] && echo 0 || echo 500ms) RYW_SECONDS=$([ $cfg = lag-ryw ] && echo 2 || echo 0)
    fresh
    docker compose run --rm -e BASE=http://app:8080 -e RESULT="$out/ryw-$cfg-$k.json" k6 run --quiet modules/m06-replication/ryw.js >/dev/null 2>&1
    echo "run $k ryw $cfg done"
  done
  for mode in async sync; do
    export APPLY_DELAY=0 RYW_SECONDS=0
    fresh
    if [ $mode = sync ]; then   # set after the replica is attached: during init there is no standby to wait for
      docker compose exec -T db psql -U postgres -qAt -c "ALTER SYSTEM SET synchronous_standby_names = '*'" \
        -c "ALTER SYSTEM SET synchronous_commit = 'remote_apply'" -c "SELECT pg_reload_conf()" >/dev/null
    fi
    ( sleep 15; date +%s.%N > "$out/failover-$mode-$k.killed"; docker kill sdlab-db-1 >/dev/null
      sleep 5; docker compose exec -T db2 psql -U postgres -qAt -c "SELECT pg_promote()" >/dev/null ) & ev=$!
    start=$(date +%s.%N)
    docker compose run --rm --no-deps -e WRITER_RATE=100 -e WRITER_SECONDS=40 app drill failover-writer > "$out/failover-$mode-$k.jsonl" 2>/dev/null || true
    wait $ev
    echo "$start" > "$out/failover-$mode-$k.start"
    docker compose exec -T db2 psql -U postgres -d shortener -qAt -c "SELECT code FROM links WHERE code LIKE 'fo-%'" > "$out/failover-$mode-$k.present"
    echo "run $k failover $mode done"
  done
done
docker compose down -v >/dev/null 2>&1
python3 tools/aggregate-m06.py "$out" "$runs"
