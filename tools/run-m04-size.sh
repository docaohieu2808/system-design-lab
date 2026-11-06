#!/usr/bin/env bash
# Module 4 part a, cache-size sweep, N runs (default 3), arms interleaved inside every run (order rotates each run).
# Same load as run-m04.sh part a: 400 preview pages/s for 60 s over 100,000 pages, Redis maxmemory = CACHE_MB, allkeys-lru.
#   z1 z2 z4 z8   Zipf-skewed keys, 1 / 2 / 4 / 8 MB (4 MB is the reference of part a)
#   u4 u8         evenly spread keys, 4 / 8 MB
# Per arm: hit ratio and database queries from the app counters, p50/p99 from k6, CPU of every sdlab-* container (k6 included),
# and Redis's own evicted_keys / used_memory. Results: modules/m04-caching/results-size/
set -euo pipefail
runs=${1:-3}; out=modules/m04-caching/results-size; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m04-caching/compose.cache.yaml
export CACHE_TTL=600 CACHE_JITTER=0 CACHE_SINGLEFLIGHT=0 CACHE_SWR=0 PAGE_DELAY_MS=0
unset REDIS_URL
arms=(z1 z2 z4 z8 u4 u8)
docker compose build app >/dev/null   # build once: code edited during a run must not slip into it
for k in $(seq 1 "$runs"); do
  for i in 0 1 2 3 4 5; do
    arm=${arms[$(( (i + k - 1) % 6 ))]}
    export CACHE_MB=${arm:1}; keys=zipf; [ "${arm:0:1}" = u ] && keys=uniform
    tag="$arm-$k"
    docker compose down -v --remove-orphans >/dev/null 2>&1 || true
    tools/quiet-gate.sh 25 2 > "$out/$tag.gate"
    docker compose up -d --wait >/dev/null; sleep 3
    python3 tools/cpu-sampler.py "$out/$tag.cpu.tsv" 1 & cs=$!
    docker compose run --rm -e BASE=http://app:8080 -e RATE=400 -e DURATION=60 -e KEYS=$keys -e RESULT="$out/$tag.json" k6 \
      run --quiet modules/m04-caching/traffic.js >/dev/null 2>&1 || echo "k6 exit $? ($tag)" >&2
    kill $cs; wait $cs 2>/dev/null || true
    curl -s localhost:8080/stats > "$out/$tag.app.json"
    docker compose exec -T redis redis-cli info stats memory | tr -d '\r' | grep -E "^(evicted_keys|expired_keys|used_memory|maxmemory):" > "$out/$tag.redis.txt"
    docker compose exec -T redis redis-cli dbsize | tr -d '\r' >> "$out/$tag.redis.txt"
    echo "run $k arm $arm done ($(cat "$out/$tag.gate"))"
  done
done
docker compose down -v --remove-orphans >/dev/null 2>&1
python3 tools/aggregate-m04-size.py "$out" "$runs"
