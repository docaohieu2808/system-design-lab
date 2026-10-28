#!/usr/bin/env bash
# Short self-check (about 1 minute): the stack starts, the app answers 302 for seeded links,
# a light load is fully served, and k6 itself is far from its CPU limit.
set -euo pipefail
export UID GID=$(id -g)
tmp=modules/m01-one-server/results/verify; mkdir -p "$tmp"
docker compose up -d --build --wait >/dev/null
code=$(curl -s -o /dev/null -w '%{http_code}' localhost:8080/1C)
[ "$code" = 302 ] || { echo "FAIL: GET /1C returned $code, want 302"; exit 1; }
( while :; do docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}'; sleep 2; done ) > "$tmp/cpu.tsv" &
sampler=$!
docker compose run --rm -e STEPS=250,500 -e HOLD=10 -e GAP=2 -e RESULT="$tmp/run.json" k6 \
  run --quiet modules/m01-one-server/find-the-ceiling.js >/dev/null
kill $sampler; wait $sampler 2>/dev/null || true
docker compose down -v >/dev/null 2>&1
python3 - "$tmp" <<'PY'
import json, sys
from pathlib import Path
d = Path(sys.argv[1]); r = json.loads((d / "run.json").read_text())
ok = True
for s in r["steps"]:
    served = s["succeeded_rps"] / s["asked_rps"]
    good = served >= 0.98 and s["dropped"] == 0
    ok &= good
    print(f"{'ok  ' if good else 'FAIL'} {s['asked_rps']} req/s asked: {s['succeeded_rps']} succeeded, p99 {s['p99_ms']} ms, dropped {s['dropped']}")
k6 = max((float(l.split('\t')[1].rstrip('%')) for l in (d / "cpu.tsv").read_text().splitlines() if '-k6-run-' in l), default=0)
good = k6 < 150
ok &= good
print(f"{'ok  ' if good else 'FAIL'} k6 peak CPU {k6:.0f}% of its 200% limit")
sys.exit(0 if ok else 1)
PY
echo "verify passed"
