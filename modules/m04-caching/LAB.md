# Module 4 — Caching: hands-on

Do this alongside lessons 4.1–4.5. **Predict first, write it down, then run.** Whole module: `make m04` (about 35 min).

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

## 2. The stampede (lesson 4.3)
```bash
CACHE_MB=64 PAGE_DELAY_MS=100 docker compose up -d --wait
( sleep 32; docker compose exec -T redis redis-cli flushall ) &
docker compose run --rm -e KEYS=zipf -e RESULT=/lab/modules/m04-caching/mine-flush.json k6 run --quiet modules/m04-caching/traffic.js
```
Watch `curl -s localhost:8080/stats` every second around the 30-second mark.
**Predict:** after the flush, how many database queries per page that had to be rebuilt?

## 3. The fixes (lesson 4.4)
Repeat step 2 with `CACHE_SINGLEFLIGHT=1`. Then try the timed version: `CACHE_TTL=20 CACHE_JITTER=0` vs
`CACHE_JITTER=0.5`, and watch database queries per second.

## If something goes wrong
- `/stats` shows zero hits: check `REDIS_URL` is not set to empty in your shell (`unset REDIS_URL`).
- Clean up: `make down`.

## Try next
Double the cache (`CACHE_MB=8`) and predict the new hit ratio for Zipf traffic. Why doesn't it double too?
