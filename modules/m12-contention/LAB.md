# Module 12 — The ticket race: hands-on

Do this alongside lessons 12.1–12.3. **Predict first, write it down, then run.** Whole module: `make m12` (3 min), with the Redis lock and the stalled holder: `make m12 LOCK=redis` (about 10 min).

```bash
export UID GID=$(id -g)
docker compose up -d --build --wait db
docker compose run --rm --no-deps -e POOL_MAX=50 app drill tickets
```
100 seats, 1,000 buyers at once, four ways to sell. **Predict:** how many orders does each way end up with?

Then read `tickets()` in `app/drills.go` and find, for the first way, the exact moment two buyers can both see room.

## 2. A lock held in Redis (lesson 12.2)
```bash
export COMPOSE_FILE=compose.yaml:modules/m12-contention/compose.redis.yaml
docker compose up -d --build --wait db redis
docker compose run --rm --no-deps -e POOL_MAX=50 -e LOCK=redis app drill tickets
```
Same 100 seats and 1,000 buyers; the line now also has `redis_lock`: every buyer takes the lock with `SET lock:event:1 <token> NX PX 5000`,
runs the check-then-insert of the broken way, and gives the lock back only if it is still theirs (`app/tickets_redis.go`).
**Predict:** orders, and time compared with the advisory lock and the conditional update.

## 3. A lease that runs out mid-work (lesson 12.2)
Three lock holders freeze for 5 seconds, right after their check and before their write, while the lock lasts only 1 second.
```bash
docker compose run --rm --no-deps -e POOL_MAX=50 -e LOCK=redis -e ARMS=redis_lock_stall app drill tickets
docker compose run --rm --no-deps -e POOL_MAX=50 -e LOCK=redis -e ARMS=redis_lock_stall_fence app drill tickets
```
The second adds a fencing token: every grant of the lock carries a number that only goes up, and the database refuses a write whose
number is lower than one it has already seen. **Predict:** how many orders beyond 100 in each case, and why.
Everything for the Redis story, 3 runs, with quiet-gate and CPU samples: `make m12 LOCK=redis` (about 10 minutes).

## Try next
Lower `POOL_MAX` to 4 and run again. Fewer buyers can talk to the database at the same moment: does the naive way
still oversell? Why is that not a fix?
