#!/usr/bin/env bash
# Module 3, the proxy's own cost: 3 app copies behind Traefik, a steady 2,000 plain redirects per second for 30 s,
# N runs (default 3). Records the peak CPU of Traefik and of each app copy. About 4 minutes.
set -euo pipefail
runs=${1:-3}; out=modules/m03-load-balancing/results-proxy; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m03-load-balancing/compose.lb.yaml APP_CPUS=0.25
docker compose build app >/dev/null
for k in $(seq 1 "$runs"); do
  docker compose down -v >/dev/null 2>&1 || true; docker compose up -d --wait --scale app=3 >/dev/null; sleep 3
  ( while :; do docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}' | grep -E "sdlab-(traefik|app|db)-"; sleep 2; done ) > "$out/run-$k.cpu.tsv" & s=$!
  docker compose run --rm -e STEPS=2000 -e HOLD=30 -e GAP=0 -e RESULT="$out/run-$k.json" k6 run --quiet modules/m01-one-server/find-the-ceiling.js >/dev/null 2>&1
  kill $s; echo "run $k done"
done
docker compose down -v >/dev/null 2>&1
python3 - "$out" "$runs" <<'PY'
import json, statistics as st, sys
from collections import defaultdict
from pathlib import Path
out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 1), "min": round(min(xs), 1), "max": round(max(xs), 1)}
tr, apps, ok = [], [], []
for k in range(1, runs + 1):
    med = defaultdict(list)
    for line in (out / f"run-{k}.cpu.tsv").read_text().splitlines():
        n, c = line.split("\t"); med[n].append(float(c.rstrip("%")))
    busy = lambda xs: st.median(sorted(xs)[len(xs) // 3:])          # typical value while loaded
    tr.append(busy(med["sdlab-traefik-1"])); apps.append(sum(busy(v) for n, v in med.items() if "-app-" in n))
    ok.append(json.loads((out / f"run-{k}.json").read_text())["steps"][0]["succeeded_rps"])
res = {"runs": runs, "rate": 2000, "succeeded_rps": agg(ok), "traefik_cpu_pct": agg(tr), "apps_total_cpu_pct": agg(apps)}
(out / "results.json").write_text(json.dumps(res, indent=1)); print(json.dumps(res, indent=1))
PY
