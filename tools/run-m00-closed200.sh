#!/usr/bin/env bash
# Module 0 variation: the 2-second freeze seen by a closed model with 10 users, with 200 users, and by an open model,
# N runs (default 3), arms interleaved inside every run (order rotates each run). 60 s each, freeze at 32 s.
#   closed10   constant-vus 10      closed200   constant-vus 200      open   800 requests/s arriving
# Results: modules/m00-the-lab/results-closed200/ (k6 and app CPU sampled)
set -euo pipefail
runs=${1:-3}; out=modules/m00-the-lab/results-closed200; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml
arms=(closed10 closed200 open)
docker compose build app >/dev/null
for k in $(seq 1 "$runs"); do
  for i in 0 1 2; do
    arm=${arms[$(( (i + k - 1) % 3 ))]}
    case $arm in closed10) model=closed; vus=10;; closed200) model=closed; vus=200;; open) model=open; vus=10;; esac
    tag="$arm-$k"
    docker compose down -v --remove-orphans >/dev/null 2>&1 || true
    tools/quiet-gate.sh 25 2 > "$out/$tag.gate"
    docker compose up -d --wait >/dev/null; sleep 3
    python3 tools/cpu-sampler.py "$out/$tag.cpu.tsv" 1 & cs=$!
    tools/freeze-app.sh 32 2 & freezer=$!
    docker compose run --rm -e MODEL=$model -e VUS=$vus -e RESULT="$out/$tag.json" k6 run --quiet modules/m00-the-lab/open-vs-closed.js >/dev/null 2>&1 || echo "k6 exit $? ($tag)" >&2
    wait $freezer; kill $cs; wait $cs 2>/dev/null || true
    echo "run $k arm $arm done ($(cat "$out/$tag.gate"))"
  done
done
docker compose down -v --remove-orphans >/dev/null 2>&1
python3 - "$out" "$runs" <<'PY'
import json, statistics as st, sys
from pathlib import Path
out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}
def cores(tag, prefix):
    rows = [(float(l.split("\t")[0]), int(l.split("\t")[2])) for l in (out / f"{tag}.cpu.tsv").read_text().splitlines() if l.split("\t")[1].startswith(prefix)]
    return (rows[-1][1] - rows[0][1]) / 1e6 / (rows[-1][0] - rows[0][0]) if len(rows) > 1 else 0
res = {"runs": runs, "freeze_s": 2, "duration_s": 60, "arms": {}}
for arm in ("closed10", "closed200", "open"):
    rows = []
    for k in range(1, runs + 1):
        r = json.loads((out / f"{arm}-{k}.json").read_text()); r.pop("model", None)
        r["k6_cores"], r["app_cores"] = cores(f"{arm}-{k}", "sdlab-k6"), cores(f"{arm}-{k}", "sdlab-app-1")
        r["background_busy_pct"] = float((out / f"{arm}-{k}.gate").read_text().split()[0].split("=")[1])
        rows.append(r)
    res["arms"][arm] = {f: agg([r[f] for r in rows]) for f in rows[0]}
(out / "results.json").write_text(json.dumps(res, indent=1)); print(json.dumps(res, indent=1))
PY
