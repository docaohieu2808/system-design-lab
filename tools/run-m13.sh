#!/usr/bin/env bash
# Capstones, N runs each (default 3). About 10 minutes.
#   13.3 news feed: 10,000 users, one celebrity followed by everyone: fan-out on write vs on read
#   13.4 chat: 500 and 1,000 WebSocket listeners in 20 rooms on one app copy; delivery time and memory per connection
set -euo pipefail
runs=${1:-3}; out=modules/m13-capstones/results; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m13-capstones/compose.chat.yaml
docker compose build app >/dev/null
for k in $(seq 1 "$runs"); do
  docker compose down -v >/dev/null 2>&1 || true; docker compose up -d --wait db >/dev/null; sleep 2
  docker compose run --rm --no-deps app drill feed > "$out/feed-$k.json" 2>/dev/null; echo "run $k feed done"
  for c in 500 1000; do
    docker compose up -d --wait app >/dev/null; sleep 2; curl -s localhost:8080/stats/chat > "$out/chat-$c-$k.idle.json"
    ( sleep 20; curl -s localhost:8080/stats/chat > "$out/chat-$c-$k.busy.json" ) & s=$!
    docker compose run --rm -e CONNS=$c -e RESULT="$out/chat-$c-$k.json" k6 run --quiet modules/m13-capstones/chat.js >/dev/null 2>&1
    wait $s; docker compose stop app >/dev/null; echo "run $k chat $c done"
  done
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
for c in ("500", "1000"):
    ch = [json.loads((out / f"chat-{c}-{k}.json").read_text()) for k in range(1, runs + 1)]
    busy = [json.loads((out / f"chat-{c}-{k}.busy.json").read_text()) for k in range(1, runs + 1)]
    idle = [json.loads((out / f"chat-{c}-{k}.idle.json").read_text()) for k in range(1, runs + 1)]
    res[f"chat_{c}"] = {"delivered_pct": agg([100 * x["received"] / max(1, x["sent_to"]) for x in ch]),
                        "delivery_p50_ms": agg([x["delivery_p50_ms"] for x in ch]), "delivery_p99_ms": agg([x["delivery_p99_ms"] for x in ch]),
                        "connections_seen": agg([b["connections"] for b in busy]),
                        "kb_per_connection": agg([1024 * (b["sys_mb"] - i["sys_mb"]) / max(1, b["connections"]) for b, i in zip(busy, idle)])}
(out / "results.json").write_text(json.dumps(res, indent=1)); print(json.dumps(res, indent=1))
PY
