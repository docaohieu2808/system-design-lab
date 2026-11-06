#!/usr/bin/env bash
# Module 4 optional arms of part b, N runs (default 3), ALL arms inside every run, interleaved (the order rotates each run),
# so the new arms share the session with the old ones. Results: modules/m04-caching/results-b-extra/
#   f500   flush, page build 500 ms, no single-flight (the existing arm, reference)     f1000  the same with a 1,000 ms build
#   e0 e0.5 eswr   expiry: no fix / 50% jitter / stale-while-revalidate (existing arms, reference)
#   e1     expiry with 100% jitter (lifetimes 10-30 s)      ecombo  50% jitter AND stale-while-revalidate
# Same as run-m04b.sh otherwise (the aggregator is copied from it: last-read counter for the stampede, straight-line fill for the worst second).
# --- text of the original header follows ---
# Module 4, the two cache-failure experiments, N runs each (default 3). About 15 minutes.
#   flush:  every request asks for one page (a home page); rebuilding it takes 500 ms; 400 req/s.
#           Redis is flushed halfway. Without / with single-flight: database queries in the 3 s after the flush.
#   expiry: 2,000 pages are cached in one burst (a warm-up after a deploy), each living 20 s, then 400 req/s spread
#           evenly over those pages. No fix / 50% TTL jitter / stale-while-revalidate: peak database queries in any
#           1 s, and p99. (Stale-while-revalidate is not in the flush experiment: a flush leaves nothing to serve.)
set -euo pipefail
runs=${1:-3}; out=${OUT:-modules/m04-caching/results-b-extra}; mkdir -p "$out"
export UID GID=$(id -g) COMPOSE_FILE=compose.yaml:modules/m04-caching/compose.cache.yaml
fresh() {  # fresh <tag>: lab down, wait for a quiet machine (background saved next to the result), lab up
  docker compose down -v >/dev/null 2>&1 || true
  tools/quiet-gate.sh 25 2 > "$out/$1.gate"; docker compose up -d --wait >/dev/null; sleep 2
}
sampler() {  # every 0.5 s: wall-clock time, database queries so far, keys in Redis
  ( while :; do
      q=$(curl -s localhost:8080/stats | python3 -c "import json,sys; print(json.load(sys.stdin)['db_queries'])" 2>/dev/null || echo -1)
      k=$(docker compose exec -T redis redis-cli dbsize 2>/dev/null | tr -d '\r' || echo -1)
      echo -e "$(date +%s.%N)\t$q\t$k"; sleep 0.5
    done ) > "$1" &
  echo $!
}
load() {  # load <result> <keys>: k6 run with a CPU sample of every sdlab-* container (k6 included) next to the result
  python3 tools/cpu-sampler.py "${1%.json}.cpu.tsv" 1 & cs=$!
  docker compose run --rm -e BASE=http://app:8080 -e RATE=400 -e PREALLOC="${PREALLOC:-300}" -e DURATION=60 -e KEYS="$2" -e HOT_PCT=100 -e RESULT="$1" k6 \
    run --quiet modules/m04-caching/traffic.js >/dev/null 2>&1
  kill $cs; wait $cs 2>/dev/null || true
}
docker compose build app >/dev/null
arms=(${ARMS:-f500 f1000 e0 e0.5 e1 eswr ecombo})   # ARMS="f500 f1000" runs only those; PREALLOC=800 gives k6 more ready users (the 1,000 ms build needs about 400 waiting at once)
n=${#arms[@]}
warm() {  # cache 2,000 pages in one burst, then note when it ended
  python3 -c "
A='0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
def b(n):
    s=''
    while n: s=A[n%62]+s; n//=62
    return s
print('\n'.join(f'http://localhost:8080/page/{b(i)}' for i in range(1,2001)))" | xargs -P 50 -n 20 curl -s -o /dev/null
}
for k in $(seq 1 "$runs"); do
  for i in $(seq 0 $((n - 1))); do
    arm=${arms[$(( (i + (n > 2 ? 2 : 1) * (k - 1)) % n ))]}
    case $arm in
      f500|f1000)
        d=${arm#f}; export CACHE_MB=64 CACHE_TTL=600 CACHE_JITTER=0 CACHE_SINGLEFLIGHT=0 CACHE_SWR=0 PAGE_DELAY_MS=$d; tag="flush-$d-$k"
        fresh "$tag"; s=$(sampler "$out/$tag.stats.tsv")
        ( sleep 32; date +%s.%N > "$out/$tag.flushed"; docker compose exec -T redis redis-cli flushall >/dev/null ) & ev=$!
        load "$out/$tag.json" hot; wait $ev; kill $s;;
      *)
        j=${arm#e}; jit=$j; swr=0
        [ $j = swr ] && { jit=0; swr=1; }; [ $j = combo ] && { jit=0.5; swr=1; }
        export CACHE_MB=64 CACHE_TTL=20 CACHE_JITTER=$jit CACHE_SINGLEFLIGHT=0 CACHE_SWR=$swr PAGE_DELAY_MS=100; tag="expiry-$j-$k"
        fresh "$tag"; s=$(sampler "$out/$tag.stats.tsv"); warm; date +%s.%N > "$out/$tag.warmed"
        load "$out/$tag.json" set; kill $s;;
    esac
    echo "run $k arm $arm done ($(cat "$out/$tag.gate"))"
  done
done
docker compose down -v >/dev/null 2>&1
python3 - "$out" "$runs" <<'PY'
import json, re, statistics as st, sys
from pathlib import Path
out, runs = Path(sys.argv[1]), int(sys.argv[2])
agg = lambda xs: {"mean": round(st.mean(xs), 2), "min": round(min(xs), 2), "max": round(max(xs), 2)}
def series(p):
    rows = []
    for l in p.read_text().splitlines():
        t, q, k = l.split("\t")
        if int(q) >= 0: rows.append((float(t), int(q)))
    return rows
# The sampler reads the counter about every 0.8 s, not every 0.5 s, so a window of 1 s can hold 0, 1 or 2 readings.
# Counting readings inside the window undercounts (a stampede that fills one gap was read as 151 instead of 201).
def hold(rows, t):  # counter at time t, as last read at or before t (right for a step such as a stampede)
    v = rows[0][1]
    for ts, q in rows:
        if ts > t: break
        v = q
    return v
def fill(rows, t):  # counter at time t, straight line between the two readings around t (right for a steady flow)
    if t <= rows[0][0]: return rows[0][1]
    for (t0, q0), (t1, q1) in zip(rows, rows[1:]):
        if t0 <= t <= t1: return q0 + (q1 - q0) * (t - t0) / (t1 - t0)
    return rows[-1][1]
def queries(rows, a, b):  # database queries between a and b, using last-read values at both ends
    return hold(rows, b) - hold(rows, a)
def queries_filled(rows, a, b):  # database queries between a and b, straight-line fill between readings
    return fill(rows, b) - fill(rows, a)
def cores(tag, part):  # average CPU cores used by containers whose name contains `part`, over their sampled life
    first, last = {}, {}
    for l in (out / f"{tag}.cpu.tsv").read_text().splitlines():
        t, name, u, *_ = l.split("\t")
        if part in name and name != "HOST":
            first.setdefault(name, (float(t), int(u))); last[name] = (float(t), int(u))
    return round(sum((last[n][1] - first[n][1]) / 1e6 / max(last[n][0] - first[n][0], 1) for n in first), 3)
def gate(tag):  # background busy % the quiet gate saw before this run
    return float(re.search(r"background_busy_pct=(\d+)", (out / f"{tag}.gate").read_text()).group(1))
res = {"runs": runs, "flush": {}, "expiry": {}}
for sf in ("500", "1000"):
    if not (out / f"flush-{sf}-1.json").exists(): continue
    rows = []
    for k in range(1, runs + 1):
        s, f = series(out / f"flush-{sf}-{k}.stats.tsv"), float((out / f"flush-{sf}-{k}.flushed").read_text())
        r6 = json.loads((out / f"flush-{sf}-{k}.json").read_text())
        rows.append({"db_queries_10s_before": queries(s, f - 10, f), "db_queries_3s_after": queries(s, f, f + 3),
                     "p99_ms": r6["p99_ms"], "max_ms": r6["max_ms"], "dropped": r6["dropped"], "background_busy_pct": gate(f"flush-{sf}-{k}"),
                     "k6_cores": cores(f"flush-{sf}-{k}", "k6"), "app_cores": cores(f"flush-{sf}-{k}", "app")})
    res["flush"][sf] = {k_: agg([r[k_] for r in rows]) for k_ in rows[0]}
for j in ("0", "0.5", "1", "swr", "combo"):
    if not (out / f"expiry-{j}-1.json").exists(): continue
    rows = []
    for k in range(1, runs + 1):
        s, w = series(out / f"expiry-{j}-{k}.stats.tsv"), float((out / f"expiry-{j}-{k}.warmed").read_text())
        per = [queries_filled(s, w + x / 2, w + x / 2 + 1) for x in range(0, 110)]
        r6 = json.loads((out / f"expiry-{j}-{k}.json").read_text())
        rows.append({"peak_db_q_in_1s": round(max(per)), "db_q_total": round(queries_filled(s, w, w + 56)), "p99_ms": r6["p99_ms"],
                     "max_ms": r6["max_ms"], "background_busy_pct": gate(f"expiry-{j}-{k}"),
                     "k6_cores": cores(f"expiry-{j}-{k}", "k6"), "app_cores": cores(f"expiry-{j}-{k}", "app")})
    res["expiry"][j] = {k_: agg([r[k_] for r in rows]) for k_ in rows[0]}
(out / "results.json").write_text(json.dumps(res, indent=1)); print(json.dumps(res, indent=1))
PY
