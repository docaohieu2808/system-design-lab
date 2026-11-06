#!/usr/bin/env bash
# Module 10, retry burst: 300 clients fail in the same moment (the app is down) and retry on the same schedule, with waits of
# exactly 1, 2, 4, 8, 16 s (no jitter) against a random wait between 0 and the same cap (full jitter). Arms interleaved in every run
# (order rotates), N runs (default 3), about 6 minutes. The app is stopped before the test and started again about 11 s after k6 was
# launched; the real return time (seconds into the test) is saved. Output: modules/m10-async/results-burst/ with a timeline per arm.
# Run it inside flock.
set -euo pipefail
runs=${1:-3}; out=modules/m10-async/results-burst; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m10-async/compose.queue.yaml QUEUE=0 SIDE_WORK_MS=0
fresh() { docker compose down -v --remove-orphans >/dev/null 2>&1 || true; tools/quiet-gate.sh 25 2 > "$out/$1.gate"; docker compose up -d --wait >/dev/null; sleep 2; }
docker compose build app >/dev/null
arms=(nojitter jitter)
for k in $(seq 1 "$runs"); do
  for n in 0 1; do
    a=${arms[$(( (n + k - 1) % 2 ))]}; t=burst-$a-$k; j=0; [ "$a" = jitter ] && j=1
    fresh $t; docker compose stop app >/dev/null
    ( sleep 11; docker compose start app >/dev/null; date +%s.%N > "$out/$t.started" ) & ev=$!
    docker compose run --rm -e JITTER=$j -e RESULT="/lab/$out/$t.json" k6 run --quiet modules/m10-async/burst.js >/dev/null 2>&1 || true
    wait $ev; echo "run $k burst $a done ($(cat $out/$t.gate))"
  done
done
docker compose down -v --remove-orphans >/dev/null 2>&1
python3 tools/aggregate-m10-burst.py "$out" "$runs"
