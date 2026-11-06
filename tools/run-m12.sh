#!/usr/bin/env bash
# Module 12, N runs (default 3). 100 seats, 1,000 buyers at once, 50 database connections.
#   make m12                    check-then-insert, SELECT ... FOR UPDATE, advisory lock, one conditional UPDATE (about 3 minutes)
#   make m12 LOCK=redis         the same four plus a lock held in Redis (SET ... NX PX), and, in every run, the two stalled-holder
#                               arms: three lock holders freeze for 5 s while the lock lasts 1 s, without and with a fencing token
#   make m12 POOL_MAX=4         the four database ways with 4 connections instead of 50, results in results-pool4/
#   make m12 LOCK=redis STALL=1            only the stalled-holder arm without a token
#   make m12 LOCK=redis STALL=1 FENCE=1    only the stalled-holder arm with a fencing token
# Before every drill: the lab is brought down and up, the quiet-machine gate runs (its reading is saved as <file>.gate) and a CPU
# sample of every sdlab container is saved as <file>.cpu.tsv.
set -euo pipefail
runs=${1:-3}; pool=${POOL_MAX:-50}; out=modules/m12-contention/results
[ "$pool" != 50 ] && out=modules/m12-contention/results-pool$pool   # make m12 POOL_MAX=4: the same race with only 4 database connections
mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml
svc=(db); lock=${LOCK:-}
[ "$lock" = redis ] && { export COMPOSE_FILE=compose.yaml:modules/m12-contention/compose.redis.yaml; svc=(db redis); }
drill() {  # drill <file tag> <extra docker -e options...>: fresh lab, quiet machine, one `drill tickets`
  local tag=$1; shift
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  tools/quiet-gate.sh 25 2 > "$out/$tag.gate"; docker compose up -d --wait "${svc[@]}" >/dev/null; sleep 2
  python3 tools/cpu-sampler.py "$out/$tag.cpu.tsv" 1 & local cs=$!
  docker compose run --rm --no-deps -e POOL_MAX=$pool "$@" app drill tickets > "$out/$tag.json" 2>/dev/null || { kill $cs 2>/dev/null; echo "drill $tag failed" >&2; exit 1; }
  kill $cs 2>/dev/null || true; wait $cs 2>/dev/null || true
  echo "$tag done"
}
docker compose build app >/dev/null
for k in $(seq 1 "$runs"); do
  if [ "$lock" != redis ]; then
    drill "tickets-$k"
  elif [ -n "${STALL:-}" ]; then
    if [ -n "${FENCE:-}" ]; then drill "tickets-stall-fence-$k" -e LOCK=redis -e ARMS=redis_lock_stall_fence
    else drill "tickets-stall-$k" -e LOCK=redis -e ARMS=redis_lock_stall; fi
  else
    drill "tickets-$k" -e LOCK=redis
    drill "tickets-stall-$k" -e LOCK=redis -e ARMS=redis_lock_stall
    drill "tickets-stall-fence-$k" -e LOCK=redis -e ARMS=redis_lock_stall_fence
  fi
done
docker compose down -v --remove-orphans >/dev/null 2>&1
python3 tools/aggregate-m12.py "$out" "$runs"
