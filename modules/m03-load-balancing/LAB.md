# Module 3 — Load balancing: hands-on

Do this alongside lessons 3.1–3.5. **Predict first, write it down, then run.** The whole module: `make m03`
(about an hour, 3 runs); the steps below run one piece at a time so you can watch.

Every command below needs these two settings in your shell first:
```bash
export COMPOSE_FILE=compose.yaml:modules/m03-load-balancing/compose.lb.yaml UID GID=$(id -g)
```

## 1. Three copies behind Traefik (lesson 3.1)
```bash
docker compose up -d --build --wait --scale app=3
for i in 1 2 3 4 5 6; do curl -s localhost:8080/page/1C | tail -c 20; done
docker compose ps
```
Traefik answers on port 8080 now and passes each request to one copy. Each copy has a quarter of a core.

## 2. Does it scale? (lesson 3.1)
```bash
for n in 1 2 3; do
  docker compose up -d --wait --scale app=$n
  docker compose run --rm -e PREFIX=page/ -e EXPECT=200 -e STEPS=150,300,450,600,750,900,1050,1200 -e HOLD=15 -e GAP=5 \
    -e RESULT=/lab/modules/m03-load-balancing/mine-$n.json k6 run --quiet modules/m01-one-server/find-the-ceiling.js
done
```
**Predict:** if one copy tops out at X, what will two and three reach? What will stop them first?
**Check:** course machine: 321 → 685 → 1,063 pages/s; the 4th copy (1,270) added less because the database filled.
Watch `docker stats` in another terminal: the database at 50% means it is full.

## 3. Kill one under load (lesson 3.2)
```bash
docker compose up -d --wait --scale app=3
( sleep 32; docker kill sdlab-app-2 ) &
docker compose run --rm -e RATE=600 -e RESULT=/lab/modules/m03-load-balancing/mine-kill.json k6 run --quiet modules/m03-load-balancing/steady.js
cat modules/m03-load-balancing/mine-kill.json
```
**Predict:** how many requests fail at the moment of the kill, and what happens to p99 after it? Then repeat with
`--scale app=4` and compare.

## 4. A frozen copy and a health check (lesson 3.3)
```bash
docker compose up -d --wait --scale app=3
( sleep 32; docker pause sdlab-app-2 ) &
docker compose run --rm -e RATE=400 -e RESULT=/lab/modules/m03-load-balancing/mine-pause.json k6 run --quiet modules/m03-load-balancing/steady.js
docker unpause sdlab-app-2
```
Then add the health check and repeat:
```bash
export COMPOSE_FILE=$COMPOSE_FILE:modules/m03-load-balancing/compose.health.yaml
```
**Predict:** how many failures with the check, compared with without? (Course machine: 3,861 vs 191.)

## 5. A slow copy (lesson 3.4)
```bash
LB_STRATEGY=wrr docker compose up -d --wait --scale app=3 && docker update --cpus 0.08 sdlab-app-3
docker compose run --rm -e RATE=400 -e RESULT=/lab/modules/m03-load-balancing/mine-wrr.json k6 run --quiet modules/m03-load-balancing/steady.js
```
Repeat with `LB_STRATEGY=p2c`. **Predict:** which one fails more requests, and by how much?

## If something goes wrong
- `port is already allocated`: `make down` (it clears every lab container), then try again.
- Traefik returns 404: the copies are not healthy yet; wait for `--wait` to finish, check `docker compose ps`.
- Your 1-copy ceiling is far lower than 321 × your calibration ratio: your machine may be busy; compare shapes anyway.

## Try next
Give each copy half a core (`APP_CPUS=0.5`) and predict where the database stops the scaling now.
Clean up: `make down`.
