#!/usr/bin/env bash
# Capstone 13.3 (news feed), N runs (default 3). About 5 minutes. 10,000 users, one celebrity followed by everyone:
# fan-out on write vs fan-out on read, time to post and to read a feed.
set -euo pipefail
runs=${1:-3}; out=modules/m13-capstones/results; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml
docker compose build app >/dev/null
for k in $(seq 1 "$runs"); do
  docker compose down -v >/dev/null 2>&1 || true; docker compose up -d --wait db >/dev/null; sleep 2
  docker compose run --rm --no-deps app drill feed > "$out/feed-$k.json" 2>/dev/null; echo "run $k feed done"
done
docker compose down -v >/dev/null 2>&1
python3 - "$out" "$runs" <<'PY'
import json, statistics as st, sys
from pathlib import Path
out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}
rows = [json.loads((out / f"feed-{k}.json").read_text().strip().splitlines()[-1]) for k in range(1, runs + 1)]
res = {"runs": runs, "users": 10000, "ordinary_followers": 100, "celebrity_followers": 9999}
for m in ("write_ordinary_ms", "write_celebrity_ms", "read_feed_p50_ms"):
    res[m] = {w: agg([r[m][w] for r in rows]) for w in ("fanout_on_write", "fanout_on_read")}
res["timeline_rows_stored"] = agg([r["timeline_rows_stored"] for r in rows])
(out / "results.json").write_text(json.dumps(res, indent=1)); print(json.dumps(res, indent=1))
PY
