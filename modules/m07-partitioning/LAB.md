# Module 7 — Partitioning: hands-on

Do this alongside lessons 7.1–7.5. **Predict first, write it down, then run.** Whole module: `make m07` (about 15 min).

```bash
export COMPOSE_FILE=compose.yaml:modules/m07-partitioning/compose.shards.yaml UID GID=$(id -g)
docker compose up -d --build --wait
```

## 1. Adding a shard (lesson 7.2)
```bash
docker compose run --rm --no-deps app drill rehash
```
**Predict:** going from 3 shards to 4, what share of a million keys changes shard with the remainder rule? With
consistent hashing? (Hint for the first: think about which keys give the same remainder for 3 and for 4.)

## 2. The celebrity (lesson 7.3)
```bash
docker compose run --rm -e HOT_PCT=0  -e RESULT=/lab/modules/m07-partitioning/mine-even.json k6 run --quiet modules/m07-partitioning/hot.js
curl -s localhost:8080/stats/shards
docker compose up -d --wait --force-recreate app
docker compose run --rm -e HOT_PCT=50 -e RESULT=/lab/modules/m07-partitioning/mine-hot.json k6 run --quiet modules/m07-partitioning/hot.js
curl -s localhost:8080/stats/shards
```
Watch `docker stats` during the second run. **Predict:** which shard fills up, and what happens to requests for
ordinary links that happen to live on it?

### The fix: cache the hot code (lesson 7.3)
```bash
HOT_CACHE=1 docker compose up -d --wait --force-recreate app
docker compose run --rm -e HOT_PCT=50 -e RESULT=/lab/modules/m07-partitioning/mine-hotfix.json k6 run --quiet modules/m07-partitioning/hot.js
curl -s localhost:8080/stats/shards      # lookups_per_shard: what the shards still see; hot_cache_hits: answered from memory
```
**Predict:** what share of the requests still reaches the hot shard, and what happens to p99? Variations: `-e HOT_PCT=20`, and
even traffic at `-e RATE=600`. `make m07-hotfix` runs even / hot / hot with cache interleaved (about 12 minutes).

## 3. Choosing an ID (lesson 7.4)
```bash
docker compose exec -T db psql -U postgres -d shortener < modules/m07-partitioning/ids.sql
```
**Predict:** rank bigint, UUIDv4 and UUIDv7 by insert time and by index size (the script prints the table and the index sizes separately).
Time making a million IDs alone: `docker compose exec -T db psql -U postgres -d shortener < modules/m07-partitioning/gen.sql`. Use the plain stack
(`COMPOSE_FILE=compose.yaml`) for the ID experiments; the shard overlay gives the database only 0.15 core. `make m07-ids` runs both, 3 runs.

## Try next
In `app/drills.go`, change `vnodes` from 100 to 10 and rerun the rehash drill (`docker compose run --rm --no-deps -e VNODES=10 app drill rehash` does it without editing). What happens to the balance between
shards (`consistent_keys_per_shard_after`)?
