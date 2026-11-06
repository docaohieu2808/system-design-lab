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

## Added 06/11/2026: the closed model with 200 users (`make m00-closed200`, `results-closed200/results.json`)
Same 60 s runs and the same 2-second freeze at 32 s, three arms with the freeze: closed with 10 users (the arm above),
closed with 200 users, open at 800/s. 3 runs, the arms interleaved inside every run (order rotates), quiet gate 25/2 before
every arm (background 7–19% busy, steal 0). k6 used 0.26 / 0.68 / 0.39 cores (limit 2): it had room.
| arm | requests in 60 s | req/s | p50 | p99 | p99.9 | max |
|---|---|---|---|---|---|---|
| closed, 10 users | 46,778 (46,179–47,489) | 780 | 1.26 ms | 7.1 ms (6.5–7.7) | 36 ms | 2,066 ms |
| closed, 200 users | 174,997 (172,318–179,290) | 2,917 | 59.5 ms | 140.9 ms (137.8–145.6) | 2,091 ms (2,072–2,114) | 2,158 ms |
| open, 800/s | 48,001 | 800 | 0.52 ms | 1,605 ms (1,561–1,683) | 2,051 ms | 2,126 ms |

What this shows: with 200 users the closed model sends 3.7 times as many requests as with 10 (2,917/s, close to the 3,000/s
the app can answer), and the freeze still does not reach p99: 200 users are stuck on one request each, 200 slow samples of
175,000 is 0.11%, so p99 stays at 141 ms and only p99.9 (2,091 ms) and max show it. More users move the freeze from p99.9
toward p99 but a closed model needs a lot of users before it can see it. The 141 ms p99 is not the freeze: at 2,917
requests/s the app is full, 200 users are in the system, and 200 / 2,917 = 69 ms is the time one waits (p50 59 ms), so this arm
measures a saturated server. The "calm" arm for 200 users was not run, so the 141 ms is not split into calm and freeze;
the 10-user arm's calm and freeze rows are in the table above (measured 29/10, not re-run).

## What it does not show
- How often real systems freeze, or for how long. The 2-second pause is chosen to make the effect easy to see.
- That open is always right: a closed model fits systems where a fixed set of clients really does wait (a batch job
  with N workers). Real users on the internet arrive on their own schedule, so the course uses open load.
- Anything about the app's ceiling: 800 req/s is about a fifth of it.

## Calibration (`make calibrate`)
On the reference machine, 29/10/2026: ceiling 4,006 req/s in the short calibration run, ratio 1.03 against the
Module 1 mean of 3,900 (`results/calibrate/calibration.json`).
