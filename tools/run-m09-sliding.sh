#!/usr/bin/env bash
# Module 9.3, the sliding window and the one-copy baseline. N runs (default 3), every arm inside every run, interleaved
# (the order rotates each run). Limit 10 requests per second per client, the client sends 50.
#   steady (30 s, 50 req/s):  local1 (one app copy, bucket in memory)   local3 (three copies, a bucket each)
#                             window (fixed window in Redis)   bucket (token bucket in Redis)   sliding (log in Redis)
#   outage (30 s, 50 req/s, token bucket in Redis, Redis paused for 10 s from about 12 s on):  outopen (fail open)
#                             outclosed (fail closed); every request's finish time is kept, so the moment the freeze
#                             takes hold can be read (tools/extract-k6-requests.py; pause/unpause epochs in *.events)
#   boundary (5 pairs of 20 + 20 requests across a second boundary):  bwindow  bbucket  bsliding
# For the Redis steady arms it also records: Redis commands counted by INFO commandstats (after CONFIG RESETSTAT) and
# MEMORY USAGE of the client's key 15 s into the load. Every arm: lab down, quiet gate, lab up, CPU sample of every
# sdlab-* container (k6 included). Results: modules/m09-rate-limiting/results-sliding/
set -euo pipefail
runs=${1:-3}; out=modules/m09-rate-limiting/results-sliding; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m03-load-balancing/compose.lb.yaml:modules/m09-rate-limiting/compose.rl.yaml
export RL_FAIL=open RL_CLIENT=xff-right XFF_INSECURE=false
arms=(local1 local3 window bucket sliding bwindow bbucket bsliding outopen outclosed)
docker compose build app >/dev/null   # build once: code edited during a run must not slip into it
rcli() { docker compose exec -T redis redis-cli "$@" | tr -d '\r'; }
for k in $(seq 1 "$runs"); do
  for i in $(seq 0 9); do
    arm=${arms[$(( (i + 3 * (k - 1)) % 10 ))]}
    case $arm in
      local1) mode=local; copies=1; test=steady;;   local3) mode=local; copies=3; test=steady;;
      window) mode=redis-window; copies=3; test=steady;; bucket) mode=redis-bucket; copies=3; test=steady;;
      sliding) mode=redis-sliding; copies=3; test=steady;;
      bwindow) mode=redis-window; copies=3; test=boundary;; bbucket) mode=redis-bucket; copies=3; test=boundary;;
      bsliding) mode=redis-sliding; copies=3; test=boundary;;
      outopen) mode=redis-bucket; copies=3; test=steady;; outclosed) mode=redis-bucket; copies=3; test=steady;;
    esac
    tag="$arm-$k"; export RL_MODE=$mode RL_FAIL=open
    outage=0; case $arm in outopen) outage=1;; outclosed) outage=1; export RL_FAIL=closed;; esac
    docker compose down -v --remove-orphans >/dev/null 2>&1 || true
    tools/quiet-gate.sh 25 2 > "$out/$tag.gate"
    docker compose up -d --wait --scale app=$copies >/dev/null; sleep 3
    redis_steady=0; [ $test = steady ] && [ $mode != local ] && [ $outage = 0 ] && redis_steady=1
    if [ $outage = 1 ]; then
      ( sleep 12; echo $(date +%s.%N) > "$out/$tag.events"; docker compose pause redis >/dev/null; date +%s.%N >> "$out/$tag.events"
        sleep 10; date +%s.%N >> "$out/$tag.events"; docker compose unpause redis >/dev/null; date +%s.%N >> "$out/$tag.events" ) & ev=$!
    fi
    if [ $redis_steady = 1 ]; then
      rcli config resetstat >/dev/null
      ( sleep 15; for key in $(rcli --scan --pattern 'r[lsw]:*'); do echo -e "$key\t$(rcli memory usage "$key")\t$(rcli type "$key")\t$(rcli object encoding "$key")"; done > "$out/$tag.memory.tsv" ) & mem=$!
    fi
    python3 tools/cpu-sampler.py "$out/$tag.cpu.tsv" 1 & cs=$!
    outopt=""; [ $outage = 1 ] && outopt="--out json=/lab/$out/$tag.raw.json"
    docker compose run --rm -e TEST=$test -e RESULT="$out/$tag.json" k6 run --quiet $outopt modules/m09-rate-limiting/limited.js >/dev/null 2>&1 || echo "k6 exit $? ($tag)" >&2
    if [ $outage = 1 ]; then wait $ev; python3 tools/extract-k6-requests.py "$out/$tag.raw.json" "$out/$tag.requests.tsv"; rm -f "$out/$tag.raw.json"; fi
    kill $cs; wait $cs 2>/dev/null || true
    if [ $redis_steady = 1 ]; then wait $mem; rcli info commandstats | grep cmdstat > "$out/$tag.commandstats.txt"; fi
    echo "run $k arm $arm done ($(cat "$out/$tag.gate"))"
  done
done
docker compose down -v --remove-orphans >/dev/null 2>&1
python3 tools/aggregate-m09-sliding.py "$out" "$runs"
