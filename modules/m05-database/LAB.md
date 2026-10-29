# Module 5 — The database: hands-on

Do this alongside lessons 5.1–5.6. **Predict first, write it down, then run.** Whole module: `make m05` (about 40 min).

```bash
export COMPOSE_FILE=compose.yaml:modules/m05-database/compose.db.yaml UID GID=$(id -g)
docker compose up -d --build --wait          # loads a million links: give it about half a minute
psql() { docker compose exec -T db psql -U postgres -d shortener -c "$1"; }
```

## 1. One missing index (lesson 5.1)
```bash
psql "EXPLAIN ANALYZE SELECT code FROM links WHERE url = 'https://example.com/articles/777777'"
psql "CREATE INDEX links_url_idx ON links (url)"
psql "EXPLAIN ANALYZE SELECT code FROM links WHERE url = 'https://example.com/articles/777777'"
```
**Predict:** how many rows does Postgres read without the index? How long does the index take to build?
Look for `Seq Scan` and `Rows Removed by Filter` before, `Index Scan` after.

## 2. N+1 (lesson 5.2)
```bash
NPLUS1=1 docker compose up -d --wait
docker compose run --rm -e PATH_TMPL=/api/recent -e RATE=200 -e RESULT=/lab/modules/m05-database/mine-n1.json k6 run --quiet modules/m05-database/get.js
```
Repeat with `NPLUS1=0`. **Predict:** how many database queries per request in each case (`curl localhost:8080/stats`)?

## 3. Too many connections (lesson 5.3)
```bash
docker run --rm -i --network sdlab_default -e PGPASSWORD=lab postgres:18.6-alpine \
  pgbench -h db -U postgres -n -c 32 -j 4 -T 20 -f /dev/stdin shortener < modules/m05-database/lookup-by-id.sql
```
Change `-c 32` to 8, 128, 512. **Predict:** does throughput keep rising with more connections? At 128 with the default
`max_connections` (100), what do you expect? Then add PgBouncer
(`COMPOSE_FILE=$COMPOSE_FILE:modules/m05-database/compose.pgbouncer.yaml`) and point pgbench at `-h pgbouncer`.

## 4. Lost updates and write skew (lessons 5.4, 5.5)
```bash
docker compose run --rm --no-deps app drill lost-update
docker compose run --rm --no-deps app drill write-skew
```
**Predict:** of 5,000 increments, how many survive the read-then-write version? In 1,000 trials at read committed, how
often does nobody end up on call?

## Try next
Rewrite the read-then-write in `app/db.go` with `SELECT ... FOR UPDATE` in a transaction and run the drill again.
