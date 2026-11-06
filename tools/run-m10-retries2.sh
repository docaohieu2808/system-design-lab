#!/usr/bin/env bash
# Module 10, retry storm with only 2 retries (retry at once vs backoff + jitter), N runs (default 3), interleaved, with the
# counting check: every slice must show dropped 0 and ended_other 0, or the arm is not a measurement.
# Output: modules/m10-async/results-retries2/ (json, .gate, .stopped, .started) and results.json. Run it inside flock.
set -euo pipefail
runs=${1:-3}; out=modules/m10-async/results-retries2; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m10-async/compose.queue.yaml QUEUE=0 SIDE_WORK_MS=0
fresh() { docker compose down -v --remove-orphans >/dev/null 2>&1 || true; tools/quiet-gate.sh 25 2 > "$out/$1.gate"; docker compose up -d --wait >/dev/null; sleep 2; }
docker compose build app >/dev/null
arms=(immediate backoff)
for k in $(seq 1 "$runs"); do
  for n in 0 1; do
    r=${arms[$(( (n + k - 1) % 2 ))]}; t=storm2-$r-$k; fresh $t
    ( sleep 12; date +%s.%N > "$out/$t.stopped"; docker compose stop app >/dev/null; sleep 10; docker compose start app >/dev/null; date +%s.%N > "$out/$t.started" ) & ev=$!
    docker compose run --rm -e RETRY=$r -e RETRIES=2 -e RESULT="/lab/$out/$t.json" k6 run --quiet modules/m10-async/create.js >/dev/null 2>&1 || true
    wait $ev; echo "run $k storm2 $r done"
  done
done
docker compose down -v --remove-orphans >/dev/null 2>&1
python3 - "$out" "$runs" <<'PY'
import json, re, statistics as st, sys
from pathlib import Path
out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}
res = {"runs": runs}
for arm in ("immediate", "backoff"):
    rows = []
    for k in range(1, runs + 1):
        t = f"storm2-{arm}-{k}"; r = json.loads((out / f"{t}.json").read_text())
        for p in ("before", "during", "after"):
            assert r[p]["began"] >= 400 and r[p]["dropped"] == 0 and r[p]["ended_other"] == 0, f"{t} {p}: dropped {r[p]['dropped']} ended_other {r[p]['ended_other']}"
        t0 = r["test_started_ms"] / 1000; back = int(float((out / f"{t}.started").read_text()) - t0) + 1; per = r["per_second_attempts"]
        rows.append({"during_attempts": r["during"]["attempts"], "after_attempts": r["after"]["attempts"],
                     "gave_up_total": sum(r[p]["gave_up"] for p in ("before", "during", "after")), "created_after": r["after"]["created"],
                     "peak_1s_after_return": max(per[back:]), "peak_1s_overall": max(per),
                     "background_busy_pct": float(re.search(r"background_busy_pct=(\d+)", (out / f"{t}.gate").read_text()).group(1))})
    res[f"storm2_{arm}"] = {f: agg([x[f] for x in rows]) for f in rows[0]}
res["dropped_and_ended_other_all_slices"] = 0
(out / "results.json").write_text(json.dumps(res, indent=1)); print(json.dumps(res, indent=1))
PY
