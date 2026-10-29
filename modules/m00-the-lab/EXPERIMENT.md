# Module 0 — open vs closed load around a 2-second freeze

## Question
Can the way a load test sends requests hide a slow server?

## Environment
Same stack as Module 1: app ½ CPU core, Postgres ½ core, k6 2 cores (`compose.yaml`). Reference machine: 4 vCPU
(AMD EPYC-Milan), 11 GB RAM, Docker. Run on 29/10/2026.

## Method
`make m00` (`tools/run-omission.sh`, `open-vs-closed.js`). Each run is 60 s on a fresh stack, 3 runs per condition.
- **closed**: 10 virtual users, each sends a request, waits for the answer, pauses 10 ms, repeats (`constant-vus`).
- **open**: 800 requests per second on schedule, whether or not answers come back (`constant-arrival-rate`).
- **freeze**: 32 s after k6 starts, `tools/freeze-app.sh` runs `docker pause` on the app for 2 s, then `docker unpause`.

## Result (mean of 3 runs; min–max in brackets)
| condition | req/s | p50 ms | p99 ms | p99.9 ms | max ms |
|---|---|---|---|---|---|
| closed, calm | 848 | 0.96 | 3.05 | 31 | 71 |
| closed, freeze | 818 | 0.96 | **3.08** (2.76–3.32) | 34 | 2,045 |
| open, calm | 800 | 0.41 | 6.6 | 46 | 70 |
| open, freeze | 800 | 0.41 | **1,542** (1,506–1,589) | 2,023 | 2,107 |

Full numbers: `results/results.json`, per run: `results/<model>-<condition>-<run>.json`.

## What it shows
With the closed model, the 2-second freeze does not move p99 at all (3.05 → 3.08 ms): while the app was frozen, the
10 users were each stuck on one request, so only 10 slow samples were recorded among ~49,000. With the open model the
same freeze sends p99 to about 1.5 s: about 1,600 requests arrived during the freeze and every one of them waited.
The freeze is visible in the closed run only as the max (≈2 s), a single number most reports never show.

## What it does not show
- How often real systems freeze, or for how long. The 2-second pause is chosen to make the effect easy to see.
- That open is always right: a closed model fits systems where a fixed set of clients really does wait (a batch job
  with N workers). Real users on the internet arrive on their own schedule, so the course uses open load.
- Anything about the app's ceiling: 800 req/s is about a fifth of it.

## Calibration (`make calibrate`)
On the reference machine, 29/10/2026: ceiling 4,006 req/s in the short calibration run, ratio 1.03 against the
Module 1 mean of 3,900 (`results/calibrate/calibration.json`).
