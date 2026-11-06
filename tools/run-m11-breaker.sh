#!/usr/bin/env bash
# Module 11 variations, N runs (default 3), every arm inside every run, interleaved (the order rotates each run).
# Breaker arms (enrich.js: 200 pages/s for 30 s, each page asks a dependency; timeout 1 s):
#   off / simple / single   dependency takes 1.5 s; BREAKER=0 / 1 (5 failures open it for 2 s, then every call goes through)
#                           / 2 (after the 2 s exactly one probe call goes through, the rest are refused until it returns)
#   d500off / d500on        dependency takes 500 ms (under the timeout); no breaker / simple breaker
# Goodput arms (goodput.js, steps 600 / 900 / 1,200 offered pages/s, 15 s each):
#   g500    no cap, a good answer is a 200 within 500 ms (reference)       g2000  no cap, within 2,000 ms
#   cap2 / cap4 / cap8      at most 2 / 4 / 8 pages built at once, the rest refused with 429
# Records p50 / p90 / p99, share of pages slower than 500 ms, dependency calls (app counter) and a CPU sample of every
# sdlab-* container (k6 included). Results: modules/m11-overload/results-breaker/
set -euo pipefail
runs=${1:-3}; out=modules/m11-overload/results-breaker; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m11-overload/compose.overload.yaml
arms=(off simple single d500off d500on g500 g2000 cap2 cap4 cap8)
n=${#arms[@]}
docker compose build app dep >/dev/null   # build once: code edited during a run must not slip into it
for k in $(seq 1 "$runs"); do
  for i in $(seq 0 $((n - 1))); do
    arm=${arms[$(( (i + 3 * (k - 1)) % n ))]}
    export BREAKER=0 MAX_INFLIGHT=0 DEP_DELAY_MS=1500; script=enrich.js; good=500
    case $arm in
      simple) BREAKER=1;; single) BREAKER=2;; d500off) DEP_DELAY_MS=500;; d500on) BREAKER=1; DEP_DELAY_MS=500;;
      g500) script=goodput.js;; g2000) script=goodput.js; good=2000;;
      cap*) script=goodput.js; MAX_INFLIGHT=${arm#cap};;
    esac
    tag="$arm-$k"
    [ -n "${ONLY:-}" ] && [[ " $ONLY " != *" $tag "* ]] && continue   # ONLY="g500-3" repeats just that arm (after an OOM-killed k6)
    docker compose down -v --remove-orphans >/dev/null 2>&1 || true
    tools/quiet-gate.sh 25 2 > "$out/$tag.gate"
    docker compose up -d --wait >/dev/null; sleep 3
    python3 tools/cpu-sampler.py "$out/$tag.cpu.tsv" 1 & cs=$!
    extra=""; [ $script = goodput.js ] && extra="-e STEPS=600,900,1200 -e GOOD_MS=$good"
    docker compose run --rm -e RESULT="$out/$tag.json" $extra k6 run --quiet modules/m11-overload/$script >/dev/null 2>&1 || echo "k6 exit $? ($tag)" >&2
    kill $cs; wait $cs 2>/dev/null || true
    curl -s localhost:8080/stats/dep > "$out/$tag.dep.json"
    echo "run $k arm $arm done ($(cat "$out/$tag.gate"))"
  done
done
docker compose down -v --remove-orphans >/dev/null 2>&1
python3 tools/aggregate-m11-breaker.py "$out" "$runs"
