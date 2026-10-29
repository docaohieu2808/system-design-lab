#!/usr/bin/env bash
# Calibrate your machine (about 2 minutes): find this machine's ceiling for the Module 1 server with a short step test,
# and print how it compares with the course's reference machine. Use the ratio to read every number in the videos.
set -euo pipefail
export UID GID=$(id -g)
REF=3900                                    # course reference machine: Module 1 ceiling, mean of 3 runs
tmp=modules/m00-the-lab/results/calibrate; mkdir -p "$tmp"
docker compose down -v >/dev/null 2>&1 || true
docker compose up -d --build --wait >/dev/null
sleep 3
docker compose run --rm -e STEPS=1000,2000,3000,4000,5000,6000 -e HOLD=10 -e GAP=3 -e RESULT="$tmp/run.json" k6 \
  run --quiet modules/m01-one-server/find-the-ceiling.js >/dev/null
docker compose down -v >/dev/null 2>&1
python3 - "$tmp" "$REF" <<'PY'
import json, os, sys
from pathlib import Path
r = json.loads((Path(sys.argv[1]) / "run.json").read_text()); ref = int(sys.argv[2])
for s in r["steps"]:
    print(f"  {s['asked_rps']:>5} req/s asked: {s['succeeded_rps']:>7} succeeded, p99 {s['p99_ms']} ms")
ceiling = max(s["succeeded_rps"] for s in r["steps"])
print(f"\nYour ceiling: about {ceiling:,.0f} req/s ({os.cpu_count()} CPUs visible).")
print(f"Course machine: {ref:,} req/s. Ratio: {ceiling / ref:.2f}x.")
print("Multiply the request rates in the videos by this ratio; compare shapes, not exact numbers.")
(Path(sys.argv[1]) / "calibration.json").write_text(json.dumps({"ceiling_rps": round(ceiling), "reference_rps": ref,
                                                                 "ratio": round(ceiling / ref, 2)}, indent=1))
PY
