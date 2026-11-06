#!/usr/bin/env bash
# Module 7.4 only: making a million IDs alone (gen.sql), then the ID-type experiment (ids.sql), N runs (default 3), then rebuild modules/m07-partitioning/results/results.json
# (rehash and hot-key numbers stay from their earlier runs). Index size is the real index (pg_stat_user_indexes.indexrelid).
set -euo pipefail
runs=${1:-3}; out=modules/m07-partitioning/results; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml
for k in $(seq 1 "$runs"); do
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  tools/quiet-gate.sh 25 2 > "$out/ids-$k.gate"
  docker compose up -d --wait db >/dev/null; sleep 3
  docker compose exec -T db psql -U postgres -d shortener -qAt < modules/m07-partitioning/gen.sql > "$out/gen-$k.txt" 2>&1
  docker compose exec -T db psql -U postgres -d shortener -qAt < modules/m07-partitioning/ids.sql > "$out/ids-$k.txt" 2>&1
  echo "run $k ids done ($(cat "$out/ids-$k.gate"))"
done
docker compose down -v --remove-orphans >/dev/null 2>&1
python3 tools/aggregate-m07.py "$out" "$runs"
