#!/usr/bin/env bash
# Module 12 follow-up, N runs (default 3): the conditional update as two autocommit statements (UPDATE, then INSERT) against
# the same UPDATE and INSERT inside one transaction, so the ranking compares the same crash-safety contract. Both arms run in
# every drill, order alternating per run. 100 seats, 1,000 buyers at once, 50 connections. Results in results-tx/.
set -euo pipefail
runs=${1:-3}; out=modules/m12-contention/results-tx; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml
docker compose build app >/dev/null
for k in $(seq 1 "$runs"); do
  arms=conditional_update,conditional_update_tx; [ $((k % 2)) = 0 ] && arms=conditional_update_tx,conditional_update
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  tools/quiet-gate.sh 25 2 > "$out/tx-$k.gate"; docker compose up -d --wait db >/dev/null; sleep 2
  python3 tools/cpu-sampler.py "$out/tx-$k.cpu.tsv" 1 & cs=$!
  docker compose run --rm --no-deps -e POOL_MAX=50 -e ARMS=$arms app drill tickets > "$out/tx-$k.json" 2>/dev/null || { kill $cs; echo "drill $k failed" >&2; exit 1; }
  kill $cs 2>/dev/null || true; wait $cs 2>/dev/null || true
  echo "run $k ($arms) done"
done
docker compose down -v --remove-orphans >/dev/null 2>&1
python3 - "$out" "$runs" <<'PY'
import json, sys
from pathlib import Path
out, n = Path(sys.argv[1]), int(sys.argv[2])
runs = [json.loads((out / f"tx-{k}.json").read_text()) for k in range(1, n + 1)]
agg = lambda v: {"mean": round(sum(v) / len(v), 2), "min": min(v), "max": max(v)}
res = {"runs": n, "seats": 100, "buyers": 1000}
for arm in ("conditional_update", "conditional_update_tx"):
    res[arm] = {f: agg([r[arm][f] for r in runs]) for f in ("orders", "oversold", "ms")}
(out / "results.json").write_text(json.dumps(res, indent=1)); print(json.dumps(res))
PY
