#!/usr/bin/env bash
# Module 12, N runs (default 3). About 3 minutes. 100 seats, 1,000 buyers at once, 50 database connections:
# check-then-insert vs SELECT ... FOR UPDATE vs advisory lock vs one conditional UPDATE.
set -euo pipefail
runs=${1:-3}; out=modules/m12-contention/results; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml
docker compose build app >/dev/null
for k in $(seq 1 "$runs"); do
  docker compose down -v >/dev/null 2>&1 || true; docker compose up -d --wait db >/dev/null; sleep 2
  docker compose run --rm --no-deps -e POOL_MAX=50 app drill tickets > "$out/tickets-$k.json" 2>/dev/null; echo "run $k tickets done"
done
docker compose down -v >/dev/null 2>&1
python3 - "$out" "$runs" <<'PY'
import json, statistics as st, sys
from pathlib import Path
out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}
rows = [json.loads((out / f"tickets-{k}.json").read_text().strip().splitlines()[-1]) for k in range(1, runs + 1)]
res = {"runs": runs, "seats": 100, "buyers": 1000}
for m in ("check_then_insert", "select_for_update", "advisory_lock", "conditional_update"):
    res[m] = {f: agg([r[m][f] for r in rows]) for f in ("orders", "oversold", "ms")}
(out / "results.json").write_text(json.dumps(res, indent=1)); print(json.dumps(res, indent=1))
PY
