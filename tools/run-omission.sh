#!/usr/bin/env bash
# Module 0: closed vs open load model, each with and without a 2-second freeze of the app, N runs each.
#   tools/run-omission.sh 3
# Writes modules/m00-the-lab/results/<model>-<calm|freeze>-K.json, then results.json (mean, min, max).
set -euo pipefail
runs=${1:-3}; out=modules/m00-the-lab/results; mkdir -p "$out"
export UID GID=$(id -g)
for k in $(seq 1 "$runs"); do
  for model in closed open; do
    for cond in calm freeze; do
      docker compose down -v >/dev/null 2>&1 || true
      docker compose up -d --build --wait >/dev/null
      sleep 3
      [ "$cond" = freeze ] && { tools/freeze-app.sh 32 2 & freezer=$!; }
      docker compose run --rm -e MODEL=$model -e RESULT="$out/$model-$cond-$k.json" k6 \
        run --quiet modules/m00-the-lab/open-vs-closed.js >/dev/null
      [ "$cond" = freeze ] && wait $freezer
      echo "run $k $model $cond done"
    done
  done
done
docker compose down -v >/dev/null 2>&1
python3 - "$out" "$runs" <<'PY'
import json, statistics as st, sys
from pathlib import Path
out, runs = Path(sys.argv[1]), int(sys.argv[2])
res = {}
for model in ("closed", "open"):
    for cond in ("calm", "freeze"):
        rows = [json.loads((out / f"{model}-{cond}-{k}.json").read_text()) for k in range(1, runs + 1)]
        res[f"{model}-{cond}"] = {f: {"mean": round(st.mean(r[f] for r in rows), 2), "min": min(r[f] for r in rows),
                                      "max": max(r[f] for r in rows)} for f in rows[0] if f != "model"}
(out / "results.json").write_text(json.dumps({"runs": runs, "freeze_s": 2, "duration_s": 60, "results": res}, indent=1))
for k, v in res.items():
    print(f"{k:14} rps {v['rps']['mean']:7} p50 {v['p50_ms']['mean']:6} p99 {v['p99_ms']['mean']:8} p99.9 {v['p999_ms']['mean']:8} max {v['max_ms']['mean']:8} dropped {v['dropped']['mean']}")
PY
