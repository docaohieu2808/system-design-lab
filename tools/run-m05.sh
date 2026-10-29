#!/usr/bin/env bash
# Module 5, five experiments, N runs each (default 3). About 40 minutes.
#   1 index:  "find the code for this long URL" at 5 req/s over a million links, before and after CREATE INDEX
#   2 nplus1: the 20 newest links with click counts at 200 req/s: one query vs 21 queries per request
#   3 conns:  pgbench, 8/32/128/512 clients each running one-row lookups for 20 s: straight to Postgres
#             (max_connections 600) vs through PgBouncer (20 real connections); plus 128 clients at the default limit
#   4 lost:   50 workers x 100 click increments: read-then-write vs UPDATE ... SET clicks = clicks + 1
#   5 skew:   two doctors go off call at once, 1,000 trials, READ COMMITTED vs SERIALIZABLE
# Writes modules/m05-database/results/*.json and results.json.
set -euo pipefail
runs=${1:-3}; out=modules/m05-database/results; mkdir -p "$out"
export UID GID=$(id -g)
DB=compose.yaml:modules/m05-database/compose.db.yaml
fresh() { docker compose down -v >/dev/null 2>&1 || true; docker compose up -d --wait >/dev/null; sleep 3; }
get() {  # get <result> <path template> <rate> [duration]
  docker compose run --rm -e BASE=http://app:8080 -e PATH_TMPL="$2" -e RATE="$3" -e DURATION="${4:-30}" -e RESULT="$1" k6 \
    run --quiet modules/m05-database/get.js >/dev/null 2>&1
}
psql() { docker compose exec -T db psql -U postgres -d shortener -qAt -c "$1"; }
bench() {  # bench <host> <clients> <seconds>: pgbench in its own container (1.5 cores), so the client never shares the database's CPU
  docker run --rm -i --network sdlab_default --cpus 1.5 -e PGPASSWORD=lab postgres:18.6-alpine \
    pgbench -h "$1" -p 5432 -U postgres -n -c "$2" -j 4 -T "$3" -f /dev/stdin shortener < modules/m05-database/lookup-by-id.sql
}

export COMPOSE_FILE=$DB; docker compose build app >/dev/null; docker compose pull -q pgbouncer 2>/dev/null || \
  COMPOSE_FILE=$DB:modules/m05-database/compose.pgbouncer.yaml docker compose pull -q pgbouncer
for k in $(seq 1 "$runs"); do
  export COMPOSE_FILE=$DB NPLUS1=0 POOL_MAX=0
  fresh
  psql "EXPLAIN (ANALYZE, FORMAT JSON) SELECT code FROM links WHERE url = 'https://example.com/articles/777777'" > "$out/index-plan-before-$k.json"
  get "$out/index-before-$k.json" "/api/lookup?url=https://example.com/articles/{id}" 5
  t0=$(date +%s.%N); psql "CREATE INDEX links_url_idx ON links (url)"; echo "$(echo "$(date +%s.%N) - $t0" | bc)" > "$out/index-build-seconds-$k.txt"
  psql "EXPLAIN (ANALYZE, FORMAT JSON) SELECT code FROM links WHERE url = 'https://example.com/articles/777777'" > "$out/index-plan-after-$k.json"
  get "$out/index-after-$k.json" "/api/lookup?url=https://example.com/articles/{id}" 5
  echo "run $k index done"
  for np in 0 1; do
    export NPLUS1=$np; fresh; curl -s -X POST localhost:8080/stats/reset
    get "$out/nplus1-$np-$k.json" /api/recent 200; curl -s localhost:8080/stats > "$out/nplus1-$np-$k.app.json"; echo "run $k nplus1=$np done"
  done
  export NPLUS1=0
  for via in direct bouncer; do
    if [ $via = bouncer ]; then export COMPOSE_FILE=$DB:modules/m05-database/compose.pgbouncer.yaml; host=pgbouncer; else export COMPOSE_FILE=$DB; host=db; fi
    fresh; psql "ALTER SYSTEM SET max_connections = 600" >/dev/null; docker compose restart db >/dev/null; sleep 5
    [ $via = bouncer ] && { docker compose restart pgbouncer >/dev/null; sleep 3; }
    for c in 8 32 128 512; do
      bench $host $c 20 > "$out/conns-$via-$c-$k.txt" 2>&1 || true
    done
    echo "run $k conns $via done"
  done
  export COMPOSE_FILE=$DB; fresh
  bench db 128 10 > "$out/conns-default-limit-$k.txt" 2>&1 || true
  docker compose run --rm --no-deps app drill lost-update > "$out/lost-$k.json"
  docker compose run --rm --no-deps app drill write-skew > "$out/skew-$k.json"
  echo "run $k drills done"
done
docker compose down -v >/dev/null 2>&1
python3 tools/aggregate-m05.py "$out" "$runs"
