#!/usr/bin/env bash
# Module 1, finer steps, N runs (default 3), arms interleaved (order rotates each run). ARMS = asked rates (default "3000 3250 3500 3750 4000"),
# WARM = the step before each (default 2000), OUT = results folder.
# Every arm is a fresh stack and a short ladder "WARM then X asked" (HOLD 20 s, GAP 5 s, like the 10-step ladder of
# find-the-ceiling.js, where X follows another step); only the X step is reported. 3,000 and 4,000 are re-run in the same
# session as anchors: compare only inside one session. k6 gets 3 GB (compose.k6mem.yaml) so it is never OOM-killed.
# Results: modules/m01-one-server/results-finer/ (+ results.json via tools/aggregate-m01-finer.py)
set -euo pipefail
runs=${1:-3}; out=${OUT:-modules/m01-one-server/results-finer}; mkdir -p "$out"
export UID GID=$(id -g) K6_CPUS=2.0 COMPOSE_FILE=compose.yaml:modules/m01-one-server/compose.k6mem.yaml
arms=(${ARMS:-3000 3250 3500 3750 4000}); n=${#arms[@]}; warm=${WARM:-2000}
lock="flock -o /tmp/claude-1000/sdlab.lock"
$lock docker compose build app >/dev/null
for k in $(seq 1 "$runs"); do
  for i in $(seq 0 $((n - 1))); do
    arm=${arms[$(( (i + k - 1) % n ))]}; tag="r$arm-$k"
    [ -n "${ONLY:-}" ] && [[ " $ONLY " != *" $tag "* ]] && continue
    $lock docker compose down -v --remove-orphans >/dev/null 2>&1 || true
    tools/quiet-gate.sh 25 2 > "$out/$tag.gate"
    $lock docker compose up -d --wait >/dev/null; sleep 3
    python3 tools/cpu-sampler.py "$out/$tag.cpu.tsv" 1 & cs=$!
    $lock nice -n 10 docker compose run --rm -e STEPS=$warm,$arm -e HOLD=20 -e GAP=5 -e RESULT="$out/$tag.json" k6 run --quiet modules/m01-one-server/find-the-ceiling.js >/dev/null 2>&1 || echo "k6 exit $? ($tag)" >&2
    kill $cs; wait $cs 2>/dev/null || true
    echo "run $k arm $arm done ($(cat "$out/$tag.gate"))"
  done
done
$lock docker compose down -v --remove-orphans >/dev/null 2>&1
python3 tools/aggregate-m01-finer.py "$out" "$runs"
