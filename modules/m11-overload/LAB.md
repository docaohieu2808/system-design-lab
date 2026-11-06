# Module 11 — Overload: hands-on

Do this alongside lessons 11.1–11.6. **Predict first, write it down, then run.** Whole module: `make m11` (about 20 min).

```bash
export COMPOSE_FILE=compose.yaml:modules/m11-overload/compose.overload.yaml UID GID=$(id -g)
```

## 1. Goodput, with and without shedding (lessons 11.1, 11.2)
```bash
MAX_INFLIGHT=0 docker compose up -d --build --wait
docker compose run --rm -e RESULT=/lab/mine-noshed.json k6 run --quiet modules/m11-overload/goodput.js
MAX_INFLIGHT=4 docker compose up -d --wait
docker compose run --rm -e RESULT=/lab/mine-shed.json k6 run --quiet modules/m11-overload/goodput.js
```
"Goodput" counts answers that are correct and within 500 ms. **Predict:** as offered load passes the ceiling, what
happens to goodput in each case?

## 2. A slow dependency and a circuit breaker (lessons 11.3, 11.4)
```bash
BREAKER=0 docker compose up -d --wait
docker compose run --rm -e RESULT=/lab/mine-nobreaker.json k6 run --quiet modules/m11-overload/enrich.js
BREAKER=1 docker compose up -d --wait
docker compose run --rm -e RESULT=/lab/mine-breaker.json k6 run --quiet modules/m11-overload/enrich.js
```
The dependency takes 1.5 s; the app waits at most 1 s. **Predict:** p50 page time in each case, and how many pages
come back without the extra data (`degraded_pct`).

Clean up: `make down`.

## Variations (added 06/11/2026)
Predict first. `make m11-breaker` runs all of these interleaved (about 40 minutes).
- Single-probe breaker: `BREAKER=2 docker compose up -d --force-recreate app`, run `enrich.js`, then `curl -s localhost:8080/stats/dep` for the
  calls that really reached the dependency; compare with `BREAKER=1` and `BREAKER=0`. `enrich.js` prints p90 and the share of pages slower than 500 ms.
- A slow but answering dependency: `DEP_DELAY_MS=500` (under the 1 s timeout), breaker off and on. Does the breaker ever open?
- A looser bar: `-e GOOD_MS=2000` on `goodput.js` at 900 offered. How much of the "lost" goodput was only late?
- Cap size: `MAX_INFLIGHT=2` and `8` next to the 4 you have run; compare what is refused at 600 and what is good at 1,200.
  If k6 is killed (exit 137) the uncapped runs ran it out of memory: the overlay gives it 3 GB.
