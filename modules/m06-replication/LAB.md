# Module 6 — Replication and failover: hands-on

Do this alongside lessons 6.1–6.5. **Predict first, write it down, then run.** Whole module: `make m06` (about 25 min).

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
**Predict:** with no added lag, how many fresh links will be missing on the replica? With half a second of lag?

## 2. Read your own writes (lesson 6.3)
`RYW_SECONDS=2 docker compose up -d --wait app`, then run the lag test again. **Predict:** how many missing now?

## 3. Kill the primary (lesson 6.4)
```bash
( sleep 15; docker kill sdlab-db-1; sleep 5; docker compose exec -T db2 psql -U postgres -c "SELECT pg_promote()" ) &
docker compose run --rm --no-deps -e WRITER_RATE=100 -e WRITER_SECONDS=40 app drill failover-writer > mine-failover.jsonl
```
**Predict:** for how many seconds will writes fail? Will any write that was confirmed be missing afterwards?
Count: gaps between successful lines (`"ok":true`) give the RTO; compare confirmed codes with
`SELECT code FROM links WHERE code LIKE 'fo-%'` on db2 for the RPO.

## Try next
Turn on synchronous replication (`ALTER SYSTEM SET synchronous_standby_names = '*'`, reload) and compare write times.
