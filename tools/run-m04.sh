#!/usr/bin/env bash
# Module 4, three experiments, N runs each (default 3). About 35 minutes.
#   1 hit:    400 req/s on the preview page for 60 s: no cache / cache + uniform keys / cache + Zipf keys (4 MB cache)
#   2 flush:  cache warm, Zipf, rebuilding a page takes 100 ms; Redis flushed halfway; without / with single-flight
#   3 expiry: every page cached with a 20 s TTL; without / with 50% TTL jitter; peak database queries per second
# Writes modules/m04-caching/results/*.json (+ *.stats.tsv: time, database queries, cache keys) and results.json.
set -euo pipefail
runs=${1:-3}; out=modules/m04-caching/results; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m04-caching/compose.cache.yaml

fresh() { docker compose down -v >/dev/null 2>&1 || true; docker compose up -d --wait >/dev/null; sleep 3; }
sampler() {  # every 0.5 s: seconds, database queries so far, keys in Redis
  ( t0=$(date +%s.%N); while :; do
      q=$(curl -s localhost:8080/stats | python3 -c "import json,sys; print(json.load(sys.stdin)['db_queries'])" 2>/dev/null || echo -1)
      k=$(docker compose exec -T redis redis-cli dbsize 2>/dev/null | tr -d '\r' || echo -1)
      echo -e "$(echo "$(date +%s.%N) - $t0" | bc)\t$q\t$k"; sleep 0.5
    done ) > "$1" &
  echo $!
}
load() {  # load <result> <keys> [event at half time]
  ( sleep 32; eval "${3:-true}" ) & ev=$!
  docker compose run --rm -e BASE=http://app:8080 -e RATE=400 -e DURATION=60 -e KEYS="$2" -e RESULT="$1" k6 \
    run --quiet modules/m04-caching/traffic.js >/dev/null 2>&1
  wait $ev; curl -s localhost:8080/stats > "${1%.json}.app.json"
}

docker compose build app >/dev/null   # build once: code edited during a run must not slip into it
for k in $(seq 1 "$runs"); do
  for cfg in nocache uniform zipf; do
    if [ $cfg = nocache ]; then export REDIS_URL=""; else unset REDIS_URL; fi
    export CACHE_MB=4 CACHE_TTL=600 CACHE_JITTER=0 CACHE_SINGLEFLIGHT=0 PAGE_DELAY_MS=0
    fresh; load "$out/hit-$cfg-$k.json" $([ $cfg = uniform ] && echo uniform || echo zipf); echo "run $k hit $cfg done"
  done
  unset REDIS_URL
  for sf in 0 1; do
    export CACHE_MB=64 CACHE_TTL=600 CACHE_JITTER=0 CACHE_SINGLEFLIGHT=$sf PAGE_DELAY_MS=100
    fresh; s=$(sampler "$out/flush-$sf-$k.stats.tsv")
    load "$out/flush-$sf-$k.json" zipf "docker compose exec -T redis redis-cli flushall >/dev/null"; kill $s; echo "run $k flush sf=$sf done"
  done
  for j in 0 0.5; do
    export CACHE_MB=64 CACHE_TTL=20 CACHE_JITTER=$j CACHE_SINGLEFLIGHT=0 PAGE_DELAY_MS=100
    fresh; s=$(sampler "$out/expiry-$j-$k.stats.tsv")
    load "$out/expiry-$j-$k.json" zipf; kill $s; echo "run $k expiry jitter=$j done"
  done
done
docker compose down -v >/dev/null 2>&1
python3 tools/aggregate-m04.py "$out" "$runs"
