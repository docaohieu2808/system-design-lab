# Module 12 — The ticket race: hands-on

Do this alongside lessons 12.1–12.3. **Predict first, write it down, then run.** Whole module: `make m12` (3 min).

```bash
export UID GID=$(id -g)
docker compose up -d --build --wait db
docker compose run --rm --no-deps -e POOL_MAX=50 app drill tickets
```
100 seats, 1,000 buyers at once, four ways to sell. **Predict:** how many orders does each way end up with?

Then read `tickets()` in `app/drills.go` and find, for the first way, the exact moment two buyers can both see room.

## Try next
Lower `POOL_MAX` to 4 and run again. Fewer buyers can talk to the database at the same moment: does the naive way
still oversell? Why is that not a fix?
