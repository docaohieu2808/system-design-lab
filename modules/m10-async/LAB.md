# Module 10 — Async work: hands-on

Do this alongside lessons 10.1–10.6. **Predict first, write it down, then run.** Whole module: `make m10` (about 25 min).

```bash
export COMPOSE_FILE=compose.yaml:modules/m10-async/compose.queue.yaml UID GID=$(id -g)
create() { docker compose run --rm "$@" k6 run --quiet modules/m10-async/create.js; }
```

## 1. Inline vs queued (lesson 10.1)
`QUEUE=0 docker compose up -d --build --wait && create -e RESULT=/lab/mine-inline.json`, then `QUEUE=1`.
**Predict:** p99 of creating a link in each case, when the side work takes 200 ms.

## 2. Consumer lag (lesson 10.2)
```bash
QUEUE=1 docker compose up -d --wait
docker compose run --rm --no-deps -e WORKERS=1 -e WORKER_SECONDS=40 app drill worker &
create -e RESULT=/lab/mine-lag.json; wait
```
**Predict:** with one worker that needs 200 ms per job and 40 jobs arriving per second, how long do jobs wait by the
end? Then try `WORKERS=16`.

## 3. Charged twice (lesson 10.3)
`docker compose run --rm --no-deps -e CRASH_PCT=10 -e IDEMPOTENT=0 app drill charges`, then `IDEMPOTENT=1`.
**Predict:** how many double charges in each case?

## 4. A poison message (lesson 10.4)
`docker compose run --rm --no-deps -e DLQ_AFTER=0 app drill poison`, then `DLQ_AFTER=3`.
**Predict:** how many good jobs finish in 10 seconds behind the bad one?

## 5. Retry storm (lesson 10.5)
```bash
QUEUE=0 SIDE_WORK_MS=0 docker compose up -d --wait
( sleep 12; docker compose pause app; sleep 10; docker compose unpause app ) &
create -e RETRY=immediate -e RESULT=/lab/mine-storm.json
```
Repeat with `RETRY=backoff`. **Predict:** how many attempts reach the app while it's frozen, in each case?

Clean up: `make down`.
