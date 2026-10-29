# Module 1 — One server, honestly measured: hands-on

Do this alongside lessons 1.1 and 1.2. **Predict first, write it down, then run.**

## 1. Find the ceiling (lesson 1.1)
```bash
make verify
make m01                # 3 runs, about 13 minutes
cat modules/m01-one-server/results/results.json
```
**Predict:** at what request rate will "succeeded" stop following "asked"? Use your ratio from `make calibrate`
(course machine: about 3,900 per second).
**Look at, per step:** `asked_rps` vs `succeeded_rps` (the ceiling is where they part), `dropped` (requests k6 could
not even send), and `peak_cpu_pct` (app and db should be the full ones, k6 should have room).

## 2. Watch it happen
In a second terminal while `make m01` runs:
```bash
docker stats
```
**Predict:** which container hits its CPU limit first? (app and db each have half a core: 50% is full.)

## 3. The average lies (lesson 1.2)
In the same `results.json`, for each step compare `avg_ms`, `p50_ms`, `p95_ms`, `p99_ms`.
**Predict:** at about three quarters of your ceiling, how many times bigger is p99 than the average?
Course machine at 3,000 req/s: average 4.9 ms, p99 42 ms (8.5×).

## 4. Shape, not numbers
Plot `p99_ms` against `asked_rps` (a spreadsheet is fine). Your curve should look like the one in lesson 1.1: flat,
then bending up well before the ceiling.

## If something goes wrong
- Ceiling far below your calibration ratio: rerun `make verify`; check `peak_cpu_pct.k6` — if k6 is near its limit,
  the tester is the bottleneck (lesson 0.5).
- Runs disagree a lot (`spread_pct` above ~10%): the machine is busy; close programs and run again.

## Try next
Give the app a whole core (`cpus: 1.0` under `app` in `compose.yaml`), predict the new ceiling, run `make m01`.
Then put it back.
