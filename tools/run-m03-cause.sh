#!/usr/bin/env bash
# Module 3, what limits the 4th copy: the scale step test (150 -> 1,350 pages/s) on 1-4 copies with per-second CPU
# and throttling of every container, then three "give it more" variants on 4 copies. N runs each (default 3).
#   base1..base4    the scale experiment itself, 1 to 4 copies (the numbers of record for the ceilings)
#   db1             4 copies, database limit 0.5 -> 1.0 core
#   traefik2        4 copies, Traefik limit 1.0 -> 2.0 cores
#   k6pin           4 copies, k6 pinned to CPU 3 alone, everything else on CPUs 0-2
# Usage: tools/run-m03-cause.sh [runs] [variants...]. Output: modules/m03-load-balancing/results-cause/
set -euo pipefail
runs=${1:-3}; shift || true
variants=${*:-base1 base2 base3 base4 db1 traefik2 k6pin}
out=modules/m03-load-balancing/results-cause; mkdir -p "$out"
export UID GID=$(id -g)
export COMPOSE_FILE=compose.yaml:modules/m03-load-balancing/compose.lb.yaml:modules/m03-load-balancing/compose.cause.yaml LB_STRATEGY=wrr
docker compose build app >/dev/null
other_max=${OTHER_MAX:-25}   # % of one core that all non-lab containers together may use during a run; more = the run is discarded and repeated
run_arm() {  # run_arm <variant> <run number>: one clean step test; returns 1 if another stack used the machine meanwhile
  local v=$1 k=$2 copies=4 rc=0 s
  case $v in base[123]) copies=${v#base};; esac
  unset DB_CPUS TRAEFIK_CPUS K6_CPUSET REST_CPUSET
  case $v in db1) export DB_CPUS=1.0;; traefik2) export TRAEFIK_CPUS=2.0;; k6pin) export K6_CPUSET=3 REST_CPUSET=0-2;; esac
  docker compose down -v >/dev/null 2>&1 || true
  tools/quiet-gate.sh 25 2 > "$out/$v-$k.gate"
  docker compose up -d --wait --scale app=$copies >/dev/null; sleep 3
  python3 tools/cpu-sampler.py "$out/$v-$k.cpu.tsv" 1 & s=$!
  trap 'kill $s 2>/dev/null' EXIT      # never leave the sampler behind if k6 fails
  docker compose run --rm -e PREFIX=page/ -e EXPECT=200 -e STEPS=150,300,450,600,750,900,1050,1200,1350 -e HOLD=15 -e GAP=5 \
    -e RESULT="$out/$v-$k.json" k6 run --quiet modules/m01-one-server/find-the-ceiling.js >/dev/null 2> >(grep -v "Request Failed" | tail -n 5 > "$out/$v-$k.k6err") || rc=$?
  kill "$s"; wait "$s" 2>/dev/null || true; trap - EXIT
  other=$(awk '$2=="OTHER"{if(!f){f=$1;a=$3} l=$1;b=$3} END{printf "%d", 100*(b-a)/1e6/(l-f)}' "$out/$v-$k.cpu.tsv")
  echo "run $k $v: k6 exit $rc, other containers $other% of a core, $(cat "$out/$v-$k.gate")"
  [ "$rc" = 0 ] && [ "$other" -le "$other_max" ]
}
for k in $(seq 1 "$runs"); do
  for v in $variants; do
    for try in 1 2 3 4 5; do
      run_arm "$v" "$k" && { echo "run $k $v done"; break; }
      echo "run $k $v discarded (attempt $try), repeating"; [ "$try" = 5 ] && { echo "run $k $v failed 5 times"; exit 1; }
    done
  done
done
docker compose down -v >/dev/null 2>&1
python3 tools/aggregate-m03-cause.py "$out" "$runs" $variants
