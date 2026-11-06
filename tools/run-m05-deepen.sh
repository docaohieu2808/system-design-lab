#!/usr/bin/env bash
# Module 5 variations, N runs (default 3), arms of one experiment interleaved inside every run (order rotates each run).
#   idx    no index, 5 req/s vs 2 vs 10 (30 s)               idx2 idx5 idx10
#   nplus1 /api/recent at 400 req/s, 30 s                   n1 (NPLUS1=1)  n0 (NPLUS1=0)
#   pool   pgbench 512 clients through PgBouncer, 20 s       p5 p20 p80   (DEFAULT_POOL_SIZE)
#   drill  lost-update with the app pool at its default / 2 / 50 connections (also read-then-write with FOR UPDATE),
#          and the write-skew drill with its FOR UPDATE variant   l0 l2 l50 skew
#   prep   pgbench, 8 clients straight to Postgres, 20 s: simple protocol vs -M prepared   s8 pr8
# Every arm: lab down, quiet gate, lab up, a CPU sample of every sdlab-* container (k6 and pgbench included).
# Results: modules/m05-database/results-deepen/
set -euo pipefail
runs=${1:-3}; out=modules/m05-database/results-deepen; mkdir -p "$out"
export UID GID=$(id -g)
DB=compose.yaml:modules/m05-database/compose.db.yaml; PGB=$DB:modules/m05-database/compose.pgbouncer.yaml
rotate() { local k=$1; shift; local n=$#; local a=("$@"); for i in $(seq 0 $((n - 1))); do echo "${a[$(( (i + k - 1) % n ))]}"; done; }
fresh() {  # fresh <tag> <compose files>: lab down, wait for a quiet machine, lab up
  export COMPOSE_FILE=$2
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  tools/quiet-gate.sh 25 2 > "$out/$1.gate"; docker compose up -d --wait >/dev/null; sleep 3
}
psql() { docker compose exec -T db psql -U postgres -d shortener -qAt -c "$1"; }
sample() { python3 tools/cpu-sampler.py "$out/$1.cpu.tsv" 1 & cs=$!; }
unsample() { kill $cs; wait $cs 2>/dev/null || true; }
get() {  # get <tag> <path template> <rate>: k6 open load for 30 s
  sample "$1"
  docker compose run --rm -e BASE=http://app:8080 -e PATH_TMPL="$2" -e RATE="$3" -e DURATION=30 -e RESULT="$out/$1.json" k6 \
    run --quiet modules/m05-database/get.js >/dev/null 2>&1 || echo "k6 exit $? ($1)" >&2
  unsample
}
bench() {  # bench <tag> <host> <clients> <seconds> [pgbench options]
  local tag=$1 host=$2 c=$3 t=$4; shift 4; sample "$tag"
  docker run --rm -i --name sdlab-pgbench --network sdlab_default --cpus 1.5 -e PGPASSWORD=lab postgres:18.6-alpine \
    pgbench -h "$host" -p 5432 -U postgres -n -c "$c" -j 4 -T "$t" "$@" -f /dev/stdin shortener < modules/m05-database/lookup-by-id.sql > "$out/$tag.txt" 2>&1 || true
  unsample
}
export NPLUS1=0 POOL_MAX=0
COMPOSE_FILE=$DB docker compose build app >/dev/null   # build once: code edited during a run must not slip into it
COMPOSE_FILE=$PGB docker compose pull -q pgbouncer 2>/dev/null || true
for k in $(seq 1 "$runs"); do
  for a in $(rotate "$k" idx2 idx5 idx10); do
    export NPLUS1=0 POOL_MAX=0; fresh "$a-$k" $DB; get "$a-$k" "/api/lookup?url=https://example.com/articles/{id}" "${a#idx}"; echo "run $k $a done"
  done
  for a in $(rotate "$k" n1 n0); do
    export NPLUS1=${a#n} POOL_MAX=0; fresh "$a-$k" $DB; curl -s -X POST localhost:8080/stats/reset
    get "$a-$k" /api/recent 400; curl -s localhost:8080/stats > "$out/$a-$k.app.json"; echo "run $k $a done"
  done
  export NPLUS1=0 POOL_MAX=0
  for a in $(rotate "$k" p5 p20 p80); do
    export POOL_SIZE=${a#p}; fresh "$a-$k" $PGB
    psql "ALTER SYSTEM SET max_connections = 600" >/dev/null; docker compose restart db >/dev/null; sleep 5
    docker compose restart pgbouncer >/dev/null; sleep 3
    bench "$a-$k" pgbouncer 512 20; echo "run $k $a done"
  done
  for a in $(rotate "$k" l0 l2 l50 skew); do
    case $a in l0) export POOL_MAX=0;; l2) export POOL_MAX=2;; l50) export POOL_MAX=50;; skew) export POOL_MAX=0;; esac
    fresh "$a-$k" $DB; sample "$a-$k"
    docker compose run --rm --no-deps app drill $([ $a = skew ] && echo write-skew || echo lost-update) > "$out/$a-$k.json"
    unsample; echo "run $k $a done"
  done
  export POOL_MAX=0
  for a in $(rotate "$k" s8 pr8); do
    fresh "$a-$k" $DB; bench "$a-$k" db 8 20 $([ $a = pr8 ] && echo "-M prepared"); echo "run $k $a done"
  done
done
COMPOSE_FILE=$DB docker compose down -v --remove-orphans >/dev/null 2>&1
python3 tools/aggregate-m05-deepen.py "$out" "$runs"
