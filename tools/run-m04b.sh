#!/usr/bin/env bash
# Module 4, the two cache-failure experiments, N runs each (default 3). About 12 minutes.
#   flush:  half of all requests ask for one page (a home page); rebuilding a page takes 500 ms; 400 req/s.
#           Redis is flushed halfway. Without / with single-flight: database queries for that one page right after.
#   expiry: 2,000 popular pages are cached in one burst (a warm-up after a deploy), each living 20 s, then 400 req/s
#           Zipf traffic. Without / with 50% TTL jitter: peak database queries per second.
set -euo pipefail
runs=${1:-3}; out=modules/m04-caching/results-b; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m04-caching/compose.cache.yaml
fresh() { docker compose down -v >/dev/null 2>&1 || true; docker compose up -d --wait >/dev/null; sleep 2; }
sampler() {  # every 0.5 s: seconds since start, database queries so far, keys in Redis
  ( t0=$(date +%s.%N); while :; do
      q=$(curl -s localhost:8080/stats | python3 -c "import json,sys; print(json.load(sys.stdin)['db_queries'])" 2>/dev/null || echo -1)
      k=$(docker compose exec -T redis redis-cli dbsize 2>/dev/null | tr -d '\r' || echo -1)
      echo -e "$(echo "$(date +%s.%N) - $t0" | bc)\t$q\t$k"; sleep 0.5
    done ) > "$1" &
  echo $!
}
load() { docker compose run --rm -e BASE=http://app:8080 -e RATE=400 -e DURATION=60 -e KEYS="$2" -e HOT_PCT=50 -e RESULT="$1" k6 \
  run --quiet modules/m04-caching/traffic.js >/dev/null 2>&1; }
docker compose build app >/dev/null
for k in $(seq 1 "$runs"); do
  for sf in 0 1; do
    export CACHE_MB=64 CACHE_TTL=600 CACHE_JITTER=0 CACHE_SINGLEFLIGHT=$sf PAGE_DELAY_MS=500; fresh
    s=$(sampler "$out/flush-$sf-$k.stats.tsv")
    ( sleep 32; date +%s.%N > "$out/flush-$sf-$k.flushed"; docker compose exec -T redis redis-cli flushall >/dev/null ) & ev=$!
    load "$out/flush-$sf-$k.json" hot; wait $ev; kill $s; echo "run $k flush sf=$sf done"
  done
  for j in 0 0.5; do
    export CACHE_MB=64 CACHE_TTL=20 CACHE_JITTER=$j CACHE_SINGLEFLIGHT=0 PAGE_DELAY_MS=100; fresh
    s=$(sampler "$out/expiry-$j-$k.stats.tsv")
    python3 -c "
A='0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
def b(n):
    s=''
    while n: s=A[n%62]+s; n//=62
    return s
print('\n'.join(f'http://localhost:8080/page/{b(i)}' for i in range(1,2001)))" | xargs -P 50 -n 20 curl -s -o /dev/null
    date +%s.%N > "$out/expiry-$j-$k.warmed"
    load "$out/expiry-$j-$k.json" zipf; kill $s; echo "run $k expiry jitter=$j done"
  done
done
docker compose down -v >/dev/null 2>&1
python3 - "$out" "$runs" <<'PY'
import json, statistics as st, sys
from pathlib import Path
out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}
def series(p):
    rows = []
    for l in p.read_text().splitlines():
        t, q, k = l.split("\t")
        if int(q) >= 0: rows.append((float(t), int(q)))
    return rows
def rate(rows, a, b):  # database queries per second between a and b seconds
    pts = [(t, q) for t, q in rows if a <= t <= b]
    return (pts[-1][1] - pts[0][1]) / (pts[-1][0] - pts[0][0]) if len(pts) > 1 else 0
res = {"runs": runs, "flush": {}, "expiry": {}}
for sf in ("0", "1"):
    rows = []
    for k in range(1, runs + 1):
        s = series(out / f"flush-{sf}-{k}.stats.tsv")
        # sampler clock: k6 starts ~1-2 s after the sampler and the flush comes 32 s after that, so ~33-35 s here
        before, after = rate(s, 20, 30), max(rate(s, x, x + 1) for x in [i / 2 for i in range(64, 80)])
        r6 = json.loads((out / f"flush-{sf}-{k}.json").read_text())
        rows.append({"db_q_per_s_before": before, "db_q_per_s_peak_after": after, "p99_ms": r6["p99_ms"], "max_ms": r6["max_ms"]})
    res["flush"][sf] = {f: agg([r[f] for r in rows]) for f in rows[0]}
for j in ("0", "0.5"):
    rows = []
    for k in range(1, runs + 1):
        s = series(out / f"expiry-{j}-{k}.stats.tsv")
        per = [rate(s, x, x + 1) for x in [i / 2 for i in range(10, 110)]]
        r6 = json.loads((out / f"expiry-{j}-{k}.json").read_text())
        rows.append({"peak_db_q_per_s": max(per), "median_db_q_per_s": st.median(per), "p99_ms": r6["p99_ms"]})
    res["expiry"][j] = {f: agg([r[f] for r in rows]) for f in rows[0]}
(out / "results.json").write_text(json.dumps(res, indent=1)); print(json.dumps(res, indent=1))
PY
