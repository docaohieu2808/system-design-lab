#!/usr/bin/env bash
# Module 11, two experiments, N runs each (default 3). About 20 minutes.
#   1 shed:    offered 300 -> 1,500 preview pages/s on one copy (half a core): everyone waits vs at most 4 at once,
#              the rest refused with 503 + Retry-After. Goodput = 200 answers within 500 ms.
#   2 breaker: 200 pages/s, each asking a dependency that takes 1.5 s (timeout 1 s): without vs with a circuit breaker
#   PARTS=shed repeats only experiment 1 (keeps the saved breaker results and their summary).
set -euo pipefail
runs=${1:-3}; parts=${PARTS:-shed,breaker}; out=modules/m11-overload/results; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m11-overload/compose.overload.yaml
fresh() { docker compose down -v --remove-orphans >/dev/null 2>&1 || true; tools/quiet-gate.sh 25 2 >/dev/null; docker compose up -d --wait >/dev/null; sleep 3; }
docker compose build app dep >/dev/null
for k in $(seq 1 "$runs"); do
  export BREAKER=0
  for n in 0 4; do export MAX_INFLIGHT=$n; fresh
    docker compose run --rm -e RESULT="$out/shed-$n-$k.json" k6 run --quiet modules/m11-overload/goodput.js >/dev/null 2>&1; echo "run $k shed $n done"; done
  export MAX_INFLIGHT=0
  [[ $parts == *breaker* ]] && for b in 0 1; do export BREAKER=$b; fresh
    docker compose run --rm -e RESULT="$out/breaker-$b-$k.json" k6 run --quiet modules/m11-overload/enrich.js >/dev/null 2>&1; echo "run $k breaker $b done"; done
done
docker compose down -v --remove-orphans >/dev/null 2>&1
python3 - "$out" "$runs" "$parts" <<'PY'
import json, statistics as st, sys
from pathlib import Path
out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}
j = lambda n: [json.loads((out / f"{n}-{k}.json").read_text()) for k in range(1, runs + 1)]
res = json.loads((out / "results.json").read_text()) if (out / "results.json").exists() and "breaker" not in sys.argv[3] else {}
res["runs"] = runs
for n in ("0", "4"):
    rows = j(f"shed-{n}")
    res[f"shed_max_inflight_{n}"] = [{"offered": s["offered"], **{f: agg([r["steps"][i][f] for r in rows]) for f in ("goodput", "slow_per_s", "refused_per_s", "failed_per_s")}}
                                     for i, s in enumerate(rows[0]["steps"])]
for b in (("0", "1") if "breaker" in sys.argv[3] else ()):
    rows = j(f"breaker-{b}")
    res[f"breaker_{b}"] = {f: agg([r[f] for r in rows]) for f in ("ok_pct", "degraded_pct", "p50_ms", "p99_ms", "dropped")}
(out / "results.json").write_text(json.dumps(res, indent=1)); print(json.dumps(res, indent=1))
PY
