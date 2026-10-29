#!/usr/bin/env bash
# Module 3, all four experiments, N runs each (default 3). About an hour.
#   1 scale: 1-4 app copies behind Traefik, step test on the preview page -> ceiling per copy count
#   2 kill:  steady 600 req/s, one copy killed halfway, with 3 copies and with 4 (one spare)
#   3 pause: steady 400 req/s, one copy frozen halfway, without and with a Traefik health check
#   4 slow:  steady 400 req/s, one of 3 copies squeezed to 0.08 core, take-turns (wrr) vs less-busy-of-two (p2c)
# Writes modules/m03-load-balancing/results/*.json (+ .cpu.tsv for scale) and results.json.
set -euo pipefail
runs=${1:-3}; out=modules/m03-load-balancing/results; mkdir -p "$out"
export UID GID=$(id -g)
LB=compose.yaml:modules/m03-load-balancing/compose.lb.yaml
HC=$LB:modules/m03-load-balancing/compose.health.yaml
HALF=30

fresh() {  # fresh <copies>: a clean stack (COMPOSE_FILE / LB_STRATEGY come from the caller)
  docker compose down -v >/dev/null 2>&1 || true
  docker compose up -d --wait --scale app="$1" >/dev/null
  sleep 3
}
sample() {  # sample <file>: container CPU and whole-machine CPU every 2 s until killed
  ( prev=($(head -1 /proc/stat)); while :; do
      docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}'
      cur=($(head -1 /proc/stat)); idle=$(( ${cur[4]} - ${prev[4]} )); tot=0
      for i in 1 2 3 4 5 6 7; do tot=$(( tot + ${cur[$i]} - ${prev[$i]} )); done
      [ $tot -gt 0 ] && echo -e "HOST\t$(( 100 * (tot - idle) / tot ))%"; prev=("${cur[@]}"); sleep 2
    done ) > "$1" &
  echo $!
}
steady() {  # steady <rate> <result> [event command run halfway]
  ( sleep $((HALF + 2)); eval "${3:-true}" ) & ev=$!
  docker compose run --rm -e RATE="$1" -e HALF=$HALF -e RESULT="$2" k6 run --quiet modules/m03-load-balancing/steady.js >/dev/null
  wait $ev
}

COMPOSE_FILE=$LB docker compose build app >/dev/null   # build once: code edited during a run must not slip into it
for k in $(seq 1 "$runs"); do
  export COMPOSE_FILE=$LB LB_STRATEGY=wrr
  for n in 1 2 3 4; do
    fresh $n; s=$(sample "$out/scale-$n-$k.cpu.tsv")
    docker compose run --rm -e PREFIX=page/ -e EXPECT=200 -e STEPS=150,300,450,600,750,900,1050,1200,1350 -e HOLD=15 -e GAP=5 \
      -e RESULT="$out/scale-$n-$k.json" k6 run --quiet modules/m01-one-server/find-the-ceiling.js >/dev/null
    kill "$s"; echo "run $k scale $n done"
  done
  for n in 3 4; do fresh $n; steady 600 "$out/kill-$n-$k.json" "docker kill sdlab-app-2 >/dev/null"; echo "run $k kill $n done"; done
  for hc in no yes; do
    export COMPOSE_FILE=$([ $hc = yes ] && echo $HC || echo $LB)
    fresh 3; steady 400 "$out/pause-$hc-$k.json" "docker pause sdlab-app-2 >/dev/null"
    docker unpause sdlab-app-2 >/dev/null; echo "run $k pause hc=$hc done"
  done
  export COMPOSE_FILE=$LB
  for st in wrr p2c; do
    export LB_STRATEGY=$st; fresh 3; docker update --cpus 0.08 sdlab-app-3 >/dev/null
    steady 400 "$out/slow-$st-$k.json"; echo "run $k slow $st done"
  done
done
docker compose down -v >/dev/null 2>&1
python3 tools/aggregate-m03.py "$out" "$runs"
