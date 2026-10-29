# Module 9 — Rate limiting: hands-on

Do this alongside lessons 9.1–9.6. **Predict first, write it down, then run.** Whole module: `make m09` (about 25 min).
Limit: 10 requests per second per client; the test client sends 50.

```bash
export COMPOSE_FILE=compose.yaml:modules/m03-load-balancing/compose.lb.yaml:modules/m09-rate-limiting/compose.rl.yaml UID GID=$(id -g)
run() { docker compose run --rm "$@" k6 run --quiet modules/m09-rate-limiting/limited.js; }
```

## 1. Three copies, separate buckets vs one shared bucket (lessons 9.1, 9.2)
```bash
RL_MODE=local docker compose up -d --build --wait --scale app=3 && run -e TEST=steady -e RESULT=/lab/mine-local.json
RL_MODE=redis-bucket docker compose up -d --wait --scale app=3 && run -e TEST=steady -e RESULT=/lab/mine-redis.json
```
**Predict:** allowed requests per second in each case.

## 2. The edge of the window (lesson 9.3)
Run `-e TEST=boundary` with `RL_MODE=redis-window`, then `redis-bucket`. **Predict:** how many of the 40 requests
straddling a second boundary get through?

## 3. Redis goes away (lesson 9.4)
```bash
RL_MODE=redis-bucket RL_FAIL=open docker compose up -d --wait --scale app=3
( sleep 12; docker compose pause redis; sleep 10; docker compose unpause redis ) &
run -e TEST=steady -e RESULT=/lab/mine-open.json
```
Repeat with `RL_FAIL=closed`. **Predict:** what does the client see during the outage in each case?

## 4. Who is the client? (lesson 9.5)
Run with `-e SPOOF=1` (a fake X-Forwarded-For on every request) under three settings:
`RL_CLIENT=xff-left XFF_INSECURE=true`, `RL_CLIENT=xff-right XFF_INSECURE=true`, `RL_CLIENT=xff-left XFF_INSECURE=false`.
**Predict:** in which setting does the fake address get the client around the limit?

Clean up: `make down`.
