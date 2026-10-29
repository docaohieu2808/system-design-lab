#!/usr/bin/env bash
# Capstone 13.3 only (news feed), N runs (default 3). Writes results/feed-N.json and updates results.json.
set -euo pipefail
runs=${1:-3}; out=modules/m13-capstones/results
export UID GID=$(id -g)
docker compose build app >/dev/null
for k in $(seq 1 "$runs"); do
  docker compose down -v >/dev/null 2>&1 || true; docker compose up -d --wait db >/dev/null; sleep 2
  docker compose run --rm --no-deps app drill feed > "$out/feed-$k.json" 2>/dev/null; echo "run $k feed done"
done
docker compose down -v >/dev/null 2>&1
python3 - "$out" "$runs" <<'PY'
import json, pathlib, statistics as st, sys
out, runs = pathlib.Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}
rows = [json.loads((out / f"feed-{k}.json").read_text().strip().splitlines()[-1]) for k in range(1, runs + 1)]
res = json.loads((out / "results.json").read_text())
for m in ("write_ordinary_ms", "write_celebrity_ms", "read_feed_p50_ms"):
    res[m] = {w: agg([r[m][w] for r in rows]) for w in ("fanout_on_write", "fanout_on_read")}
(out / "results.json").write_text(json.dumps(res, indent=1) + "\n")
print(json.dumps({m: res[m] for m in ("write_ordinary_ms", "write_celebrity_ms", "read_feed_p50_ms")}))
PY
