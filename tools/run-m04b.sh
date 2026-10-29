#!/usr/bin/env bash
# Module 4, the two cache-failure experiments, N runs each (default 3). About 12 minutes.
#   flush:  every request asks for one page (a home page); rebuilding it takes 500 ms; 400 req/s.
#           Redis is flushed halfway. Without / with single-flight: database queries in the 3 s after the flush.
#   expiry: 2,000 pages are cached in one burst (a warm-up after a deploy), each living 20 s, then 400 req/s spread
#           evenly over those pages. Without / with 50% TTL jitter: peak database queries in any 1 s.
set -euo pipefail
runs=${1:-3}; out=modules/m04-caching/results-b; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m04-caching/compose.cache.yaml
fresh() { docker compose down -v >/dev/null 2>&1 || true; docker compose up -d --wait >/dev/null; sleep 2; }
sampler() {  # every 0.5 s: wall-clock time, database queries so far, keys in Redis
  ( while :; do
      q=$(curl -s localhost:8080/stats | python3 -c "import json,sys; print(json.load(sys.stdin)['db_queries'])" 2>/dev/null || echo -1)
      k=$(docker compose exec -T redis redis-cli dbsize 2>/dev/null | tr -d '\r' || echo -1)
      echo -e "$(date +%s.%N)\t$q\t$k"; sleep 0.5
    done ) > "$1" &
  echo $!
}
load() { docker compose run --rm -e BASE=http://app:8080 -e RATE=400 -e DURATION=60 -e KEYS="$2" -e HOT_PCT=100 -e RESULT="$1" k6 \
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
    load "$out/expiry-$j-$k.json" set; kill $s; echo "run $k expiry jitter=$j done"
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
def queries(rows, a, b):  # database queries between wall-clock times a and b
    pts = [q for t, q in rows if a <= t <= b]
    return pts[-1] - pts[0] if len(pts) > 1 else 0
res = {"runs": runs, "flush": {}, "expiry": {}}
for sf in ("0", "1"):
    rows = []
    for k in range(1, runs + 1):
        s, f = series(out / f"flush-{sf}-{k}.stats.tsv"), float((out / f"flush-{sf}-{k}.flushed").read_text())
        r6 = json.loads((out / f"flush-{sf}-{k}.json").read_text())
        rows.append({"db_queries_10s_before": queries(s, f - 10, f), "db_queries_3s_after": queries(s, f, f + 3),
                     "p99_ms": r6["p99_ms"], "max_ms": r6["max_ms"]})
    res["flush"][sf] = {k_: agg([r[k_] for r in rows]) for k_ in rows[0]}
for j in ("0", "0.5"):
    rows = []
    for k in range(1, runs + 1):
        s, w = series(out / f"expiry-{j}-{k}.stats.tsv"), float((out / f"expiry-{j}-{k}.warmed").read_text())
        per = [queries(s, w + x / 2, w + x / 2 + 1) for x in range(0, 110)]
        r6 = json.loads((out / f"expiry-{j}-{k}.json").read_text())
        rows.append({"peak_db_q_in_1s": max(per), "db_q_total": queries(s, w, w + 56), "p99_ms": r6["p99_ms"]})
    res["expiry"][j] = {k_: agg([r[k_] for r in rows]) for k_ in rows[0]}
(out / "results.json").write_text(json.dumps(res, indent=1)); print(json.dumps(res, indent=1))
PY
