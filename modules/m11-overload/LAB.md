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
