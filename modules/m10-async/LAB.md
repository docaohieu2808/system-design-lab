# Module 10 — Async work: hands-on

Do this alongside lessons 10.1–10.7. **Predict first, write it down, then run.** Whole module: `make m10` (about 30 min); only the retry-storm arms: `make m10 RETRY=backoff-nojitter` (about 10 min).

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
The app is stopped (not frozen) for 10 seconds in the middle of a 30-second run of 40 creates a second. Stopping makes requests
fail at once, as they would behind a load balancer; `docker compose pause` makes every attempt hang for the 2-second timeout
and hides the difference between the three clients.
```bash
QUEUE=0 SIDE_WORK_MS=0 docker compose up -d --wait
( sleep 12; docker compose stop app; sleep 10; docker compose start app ) &
create -e RETRY=immediate -e RESULT=/lab/mine-storm.json
```
Repeat (bring the app back up first) with `RETRY=backoff` and `RETRY=backoff-nojitter`: the same waits of about 200 ms, 400 ms, ...
with and without the random factor. **Predict:** how many attempts reach the app while it is down, in each case? Who gives up?
The result file lists `per_second_attempts` (attempts in each second of the test): find the busiest second after the app is back.
All three arms, interleaved, 3 runs, with CPU samples: `make m10 RETRY=backoff-nojitter` (about 10 minutes).

## 6. Variations
`make m10-extras` (about 75 minutes) repeats lessons 10.1-10.5 with other settings, in `results-extras/`: side work 400 ms instead of 200, 4 and 8 workers,
a 30% crash rate, a dead-letter limit of 30 tries, and a retry storm with only 2 retries (`-e RETRIES=2` on `create.js`).
**Predict:** how many jobs 4 workers finish in 40 s (each job takes 200 ms)? How many double charges at 30%? How many attempts reach the app during the outage with 2 retries?
(Course machine: 781, 432, 1,114 with retry-at-once.)

## 7. Retry burst (lesson 10.6)
`make m10-burst` (about 6 minutes): 300 clients fail in the same moment because the app is down, then retry with waits of exactly 1, 2, 4, 8, 16 s (no jitter) or a random time up to each of those (full jitter).
The app comes back about 10 s in. It writes `results-burst/timeline-nojitter.tsv` and `timeline-jitter.tsv` (attempts per 100 ms): open them and look for the spikes.
**Predict:** how many attempts reach the app in the busiest 100 ms after the first try, without and with jitter? How many clients give up? (Course machine: 281 against 50; 0 against 52.)

Clean up: `make down`.
