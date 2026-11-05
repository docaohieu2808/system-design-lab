# Module 4 — Caching: hands-on

Do this alongside lessons 4.1–4.5. **Predict first, write it down, then run.** Whole module: `make m04` (about 50 min, runs the hit-ratio part and the stampede/expiry part).

```bash
export COMPOSE_FILE=compose.yaml:modules/m04-caching/compose.cache.yaml UID GID=$(id -g)
```

## 1. Cache-aside, and the hit ratio (lessons 4.1, 4.2)
```bash
REDIS_URL= docker compose up -d --build --wait                       # no cache
docker compose run --rm -e KEYS=zipf -e RESULT=/lab/modules/m04-caching/mine-none.json k6 run --quiet modules/m04-caching/traffic.js
curl -s localhost:8080/stats
docker compose up -d --wait                                          # with the 4 MB cache
curl -s -X POST localhost:8080/stats/reset
docker compose run --rm -e KEYS=zipf -e RESULT=/lab/modules/m04-caching/mine-zipf.json k6 run --quiet modules/m04-caching/traffic.js
curl -s localhost:8080/stats
```
**Predict:** the cache holds about one page in ten. What share of requests will it answer (the hit ratio)?
Repeat with `KEYS=uniform`. **Predict:** what happens to the hit ratio when every link is equally popular?
`db_queries` in `/stats` is how many requests still reached the database.

## 2. The stampede after a wipe (lesson 4.3)
Every request asks for one page (a home page) and rebuilding it takes 500 ms; at 32 s Redis is wiped.
```bash
export CACHE_MB=64 CACHE_TTL=600 PAGE_DELAY_MS=500
docker compose up -d --wait
( sleep 32; docker compose exec -T redis redis-cli flushall ) &
docker compose run --rm -e KEYS=hot -e HOT_PCT=100 -e RESULT=/lab/modules/m04-caching/mine-flush.json k6 run --quiet modules/m04-caching/traffic.js
```
Read `curl -s localhost:8080/stats` just before the wipe (about 28 s in) and 3 s after it (about 35 s in); the difference
in `db_queries` is the stampede. **Predict first:** 400 requests/s, 0.5 s to rebuild: how many identical queries in those
first seconds? (You should see about 130-200. A 100 ms rebuild, or a Zipf mix of pages, buries the signal in ordinary
misses; that is why this step uses one page and 500 ms.)

## 3. The fixes (lesson 4.4)
**Single-flight.** Repeat step 2 with `CACHE_SINGLEFLIGHT=1`. **Predict:** how many queries now? (1.) Also read p99 in
`mine-flush.json`.

**Expiry of many pages: no fix, jitter, stale-while-revalidate.** Cache 2,000 pages in one burst, each living 20 s, then
send 400 requests/s spread over those same pages. Run it three times, changing only the cache settings:
```bash
export CACHE_MB=64 CACHE_TTL=20 PAGE_DELAY_MS=100
for pair in "0 0" "0.5 0" "0 1"; do set -- $pair      # jitter, stale-while-revalidate
  CACHE_JITTER=$1 CACHE_SWR=$2 docker compose up -d --force-recreate --wait app && docker compose exec -T redis redis-cli flushall
  python3 -c "
A='0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
def b(n):
    s=''
    while n: s=A[n%62]+s; n//=62
    return s
print('\n'.join(f'http://localhost:8080/page/{b(i)}' for i in range(1,2001)))" | xargs -P 50 -n 20 curl -s -o /dev/null
  docker compose run --rm -e KEYS=set -e RESULT=/lab/modules/m04-caching/mine-expiry-$1-$2.json k6 run --quiet modules/m04-caching/traffic.js
  curl -s localhost:8080/stats
done
```
This needs pages 1-2,000 to exist in the database (the lab seeds 100,000 links at startup). Sample
`curl -s localhost:8080/stats` every second from about 18 s on and note the busiest second of `db_queries` growth.
**Predict:** which arm has the lowest worst second? Which has the lowest p99? (Jitter spreads the refills so the database
sees fewer queries at once; stale-while-revalidate does as many but nobody waits for them, so p99 collapses. The runner
`tools/run-m04b.sh` does all of this, and the stats counter reset, for you.)

## If something goes wrong
- `/stats` shows zero hits: check `REDIS_URL` is not set to empty in your shell (`unset REDIS_URL`).
- Clean up: `make down`.

## Try next
Double the cache (`CACHE_MB=8`) and predict the new hit ratio for Zipf traffic. Why doesn't it double too?
