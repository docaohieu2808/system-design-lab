# Module 6 — Replication and failover: hands-on

Do this alongside lessons 6.1–6.5. **Predict first, write it down, then run.** Whole module: `make m06` (about 25 min), plus `make m06-reads` (about 80 min) and `make m06-extras` (about 15 min).

```bash
export COMPOSE_FILE=compose.yaml:modules/m06-replication/compose.replica.yaml UID GID=$(id -g)
docker compose up -d --build --wait
docker compose exec db psql -U postgres -c "SELECT application_name, state, replay_lag FROM pg_stat_replication"
```

## 1. Stale reads (lesson 6.2)
```bash
docker compose run --rm -e RESULT=/lab/modules/m06-replication/mine-nolag.json k6 run --quiet modules/m06-replication/ryw.js
APPLY_DELAY=500ms docker compose up -d --wait --force-recreate db2
docker compose run --rm -e RESULT=/lab/modules/m06-replication/mine-lag.json k6 run --quiet modules/m06-replication/ryw.js
```
**Predict:** with no added lag, how many fresh links will be missing on the replica? With half a second of lag? With only 50 ms (`APPLY_DELAY=50ms`)?

## 2. Read your own writes (lesson 6.3)
`RYW_SECONDS=2 docker compose up -d --wait app`, then run the lag test again. **Predict:** how many missing now?
Edge: make the window shorter than the lag and wait before opening: `APPLY_DELAY=1500ms RYW_SECONDS=1 docker compose up -d --wait --force-recreate db2 app`, then add `-e READ_DELAY=1.2` to the k6 command (it waits 1.2 s between the create and the open). **Predict:** how many missing?

## 3. Kill the primary (lesson 6.4)
```bash
( sleep 15; docker kill sdlab-db-1; sleep 5; docker compose exec -T db2 psql -U postgres -c "SELECT pg_promote()" ) &
docker compose run --rm --no-deps -e WRITER_RATE=100 -e WRITER_SECONDS=40 app drill failover-writer > mine-failover.jsonl
```
(For a faster promotion change `sleep 5` to `sleep 2`.) **Predict:** for how many seconds will writes fail? Will any write that was confirmed be missing afterwards?
Count: gaps between successful lines (`"ok":true`) give the RTO; compare confirmed codes with
`SELECT code FROM links WHERE code LIKE 'fo-%'` on db2 for the RPO.

## 4. Does a replica raise the read ceiling? (lesson 6.1)
Find where reads stop being sustained, first with every read on the primary alone, then with every read on the replica.
Same ladder as lesson 1.1, reads only. Whole experiment (five arms, 3 runs, about 80 minutes): `make m06-reads`.
```bash
export COMPOSE_FILE=compose.yaml:modules/m06-replication/compose.replica.yaml:modules/m06-replication/compose.reads.yaml UID GID=$(id -g)
STEPS=1750,2000,2250,2500,2750,3000,3500
# A: reads on the primary alone (an empty READ_DATABASE_URL turns the replica pool off)
READ_DATABASE_URL= docker compose up -d --build --wait
docker compose run --rm -e STEPS=$STEPS -e RESULT=/lab/modules/m06-replication/mine-reads-A.json k6 run --quiet modules/m01-one-server/find-the-ceiling.js
# B: reads on the replica
docker compose up -d --wait --force-recreate app
docker compose run --rm -e STEPS=$STEPS -e RESULT=/lab/modules/m06-replication/mine-reads-B.json k6 run --quiet modules/m01-one-server/find-the-ceiling.js
```
**Predict:** which step is the last one where `succeeded_rps` equals `asked_rps` and `dropped` is 0, for A and for B?
Will B be higher? While a run goes, watch `docker stats` in another terminal: which container is at 50%?

Then give the app a full core and repeat: `APP_CPUS=1.0 docker compose up -d --wait --force-recreate app` with
`STEPS=2000,2500,3000,3500,4000,5000,6000`. **Predict:** now which container is at its limit, and does the replica help?
Last, split reads over both databases (`READ_SPREAD=1 APP_CPUS=1.0 docker compose up -d --wait --force-recreate app`).
Check the last step in the result file with `succeeded_rps` still close to `asked_rps`.

## Try next
Turn on synchronous replication (`ALTER SYSTEM SET synchronous_standby_names = '*'`, reload) and compare write times.
