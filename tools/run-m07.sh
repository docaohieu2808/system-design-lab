#!/usr/bin/env bash
# Module 7, three experiments, N runs each (default 3). About 15 minutes.
#   1 rehash: 1,000,000 codes on 3 shards then 4: share of codes that change shard, modulo vs consistent hashing
#   2 hot:    1,800 redirects/s over 3 shards (0.15 core each): every code equally likely vs 50% to one code
#   3 ids:    insert a million rows with a bigint, UUIDv4 and UUIDv7 primary key: time and index size
set -euo pipefail
runs=${1:-3}; out=modules/m07-partitioning/results; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m07-partitioning/compose.shards.yaml
fresh() { docker compose down -v --remove-orphans >/dev/null 2>&1 || true; docker compose up -d --wait >/dev/null; sleep 3; }
docker compose build app >/dev/null
for k in $(seq 1 "$runs"); do
  fresh
  docker compose run --rm --no-deps app drill rehash > "$out/rehash-$k.json"
  for hot in 0 50; do
    fresh
    ( while :; do docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}' | grep -E "sdlab-(db|db2|db3|app)-1"; sleep 2; done ) > "$out/hot-$hot-$k.cpu.tsv" & s=$!
    docker compose run --rm -e BASE=http://app:8080 -e HOT_PCT=$hot -e RESULT="$out/hot-$hot-$k.json" k6 run --quiet modules/m07-partitioning/hot.js >/dev/null 2>&1
    kill $s; curl -s localhost:8080/stats/shards > "$out/hot-$hot-$k.shards.json"; echo "run $k hot $hot done"
  done
  fresh
  docker compose exec -T db psql -U postgres -d shortener -qAt < modules/m07-partitioning/ids.sql > "$out/ids-$k.txt" 2>&1
  echo "run $k ids done"
done
docker compose down -v --remove-orphans >/dev/null 2>&1
python3 tools/aggregate-m07.py "$out" "$runs"
