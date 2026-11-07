# Module 1 — One server, honestly measured

**Question:** how many requests per second can one small server answer before it stops keeping up, and what happens
to latency on the way there?

## Environment (reference machine)
- VPS, 4 vCPU AMD EPYC-Milan, 11.6 GB RAM, Ubuntu 24.04.5, kernel 6.8, Docker 29.9.2, Compose 5.6.1.
- **Shared host:** other services run on the same machine, so tail latency (p99) is noisier than on an idle laptop.
- Containers (from `compose.yaml`): `app` (Go URL shortener) **0.5 CPU**, 512 MB · `db` (PostgreSQL 18.6, 100,000
  seeded links) **0.5 CPU**, 1 GB · `k6` 1.8.2 **2 CPU**, 1 GB.

## Method
- Open model: `constant-arrival-rate`, steps 250 → 5,000 req/s, 20 s each, 5 s gap. Every request is `GET /{code}`
  for a random seeded code; the expected answer is `302` (redirects are not followed).
- Fresh stack for every run (`docker compose down -v` / `up --wait`), 3 s warm-up, **3 runs** (`make m01`).
- Recorded per step: requests sent, completed (no error), succeeded (got 302), dropped (k6 could not send),
  p50 / p95 / p99 / average latency. Peak CPU of every lab container sampled every 2 s.
- Raw runs: `results/run-1..3.json` + `.cpu.tsv`; aggregate: `results/results.json`.

## Results (mean of 3 runs, range in brackets)
| Asked req/s | Succeeded req/s | p50 ms | p99 ms | Average ms | Not sent |
|---|---|---|---|---|---|
| 250 | 250 | 0.48 | 1.8 (1.5–2.2) | 0.57 | 0 |
| 1,000 | 1,000 | 0.40 | 3.1 (2.8–3.4) | 0.57 | 0 |
| 2,000 | 2,000 | 0.44 | 14.7 (11.5–20.8) | 0.89 | 0 |
| 3,000 | 3,000 | 0.54 | 42.0 (40.7–43.5) | 4.92 | 0 |
| 4,000 | 3,900 (3,866–3,930) | 117 | 238 (204–277) | 116 | 2,002 |
| 5,000 | 4,042 (3,927–4,121) | 395 | 1,045 (823–1,476) | 411 | 18,389 |

Peak CPU: app 54% and db 52% of one core (both at their 0.5-core limit), k6 152% of its 2-core limit (not saturated).

## Added 06/11/2026: a stronger app, a squeezed load generator (`make m01-variations`, `results-variations/results.json`)
`tools/run-m01-variations.sh`: the same 10-step ceiling test, 3 runs, the three arms interleaved inside every run (order
rotating), fresh stack and quiet gate 25/2 before every arm (background 7–20% busy, steal 0). Arms: `base` (the lab as it is),
`k6half` (`K6_CPUS=0.5`), `app1` (the app gets 1.0 core: `compose.app1core.yaml`). k6 gets 3 GB of memory in all arms
(`compose.k6mem.yaml`): with the default 1 GB k6 was killed (exit 137) at the 5,000/s step in 2 of 3 base runs and, in the third,
degraded (1,895 succeeded); those base runs were repeated with 3 GB. Memory is not CPU, so this does not change what is measured.
This session's machine is slower than on 30/10: the base arm's top is 3,090 against 4,042 in the table above, so compare the
arms below with each other.
| arm | succeeded at the 5,000/s step (the ceiling) | succeeded at 4,000 | p99 at the 1,000 step | k6 cores / app cores / db cores in the last 20 s |
|---|---|---|---|---|
| base (app 0.5 core) | 3,090 (3,080–3,111) | 3,101 (3,007–3,226) | 27 ms (23–31) | 1.03 / 0.48 / 0.41 |
| k6 limited to 0.5 core | 1,924 (1,873–1,998) | 1,935 (1,863–2,003) | 104.5 ms (31–186) | 0.50 / 0.35 / 0.28 |
| app with 1.0 core | 3,678 (3,572–3,778) | 3,583 (3,557–3,626) | 5.1 ms (3.1–7.5) | 1.18 / 0.61 / 0.48 |

Squeezed generator: k6 sat at its 0.5-core cap, the app used only 0.35 of its 0.5 and the database 0.28, and the "ceiling" fell to
1,924: the tester, not the server, set the number, and p99 at the easy 1,000/s step went from 27 to 105 ms (the spread, 31–186,
is wide: the tester pauses when its quota runs out). Stronger app: giving the app a whole core raised the ceiling only 19%
(3,090 to 3,678) because the database, at 0.45–0.49 of its 0.5-core cap, became the limit while the app used 0.61 of its 1.0.
Doubling one part's CPU does not double the system; the next narrowest part takes over. p99 at the 5,000 step of the
app1 arm spreads 1,067–2,564 ms, a queue tail at saturation.

## Added 07/11/2026: finer steps (`make m01-finer`; `results-finer/`, `results-finer-below/`, `results-finer-knee/`, each with `results.json`)
**Question.** Capacity at p99 under 50 ms was "3,000 passed, 4,000 failed, nothing in between". Where between them does the goal break?
**Method.** `tools/run-m01-finer.sh`: each arm is a fresh stack and a two-step ladder "warm-up step, then X asked" (20 s per step, 5 s gap, the same
`find-the-ceiling.js` as above; X follows another step as it does in the 10-step ladder), only the X step is reported. 3 runs, the arms of a set interleaved (order
rotating), quiet gate 25/2 before every arm (background 7-17% busy, steal 0), k6 with 2 cores and 3 GB, run under `nice -n 10`; app 0.5 core, database 0.5 core.
Sets: `results-finer` asked 3,000 / 3,250 / 3,500 / 3,750 / 4,000 (3,000 and 4,000 are the anchors; warm-up 2,000); then, because those turned out to be past the
limit, `results-finer-below` asked 1,500 to 2,750 in 250s and `results-finer-knee` asked 1,250 / 1,375 / 1,500 (warm-up 1,000 in both).

**This day the machine was slower than on 30/10.** The same test answered 3,000 asked with p99 42 ms on 30/10 (table above) and with p99 301 ms (233-388) in the anchor
below; the most the server answered fell from about 4,040 to about 3,065 (app at its 0.5-core limit, 0.48-0.50 cores). The app code at the commit of the first results
(`ddd6e61`) gave the same two spot checks the same morning (2,000 then 3,000 asked: p99 282 ms; 2,000 then 4,000: 3,193 succeeded), so the change is the host, not the code.
Compare the rows below with each other, not with the table at the top.

**Steps from 3,000 to 4,000 asked (mean of 3 runs, min-max).** Every step is past this day's limit: the server answered about 3,000 a second whatever was asked, and p99
was above the goal in every run.
| Asked req/s | Succeeded req/s | p99 ms |
|---|---|---|
| 3,000 (anchor) | 2,926 (2,864-2,968) | 301 (233-388) |
| 3,250 | 2,998 (2,946-3,066) | 583 (534-615) |
| 3,500 | 3,055 (2,978-3,131) | 741 (599-860) |
| 3,750 | 3,065 (3,014-3,113) | 1,068 (959-1,124) |
| 4,000 (anchor) | 3,042 (3,009-3,083) | 1,288 (1,066-1,526) |

k6 did not send some of the arrivals in these steps (1,472 at 3,000 up to 19,167 at 4,000, `results-finer/results.json`). How many are not sent depends on the generator's
VU settings (start-up of extra VUs, the 3,000-VU cap) as much as on the server, so these counts are not used for any claim; the plateau of succeeded and the p99 far above
the goal are the result.

**Steps below, where the goal breaks this day (nothing dropped up to 2,000 asked; k6 used 0.5-0.7 core).** Rows with dropped arrivals (2,250 and above: 52 / 868 / 538 on
average) are not shown.
| Asked req/s | p50 ms | p99 ms | p99 under 50 ms in |
|---|---|---|---|
| 1,000 (warm-up step of 27 ladders) | 0.55 | 24.5 (18.3-30.6) | 27 of 27 runs |
| 1,250 | 0.55 | 35.9 (31.7-39.2) | 3 of 3 |
| 1,375 | 0.57 | 55.7 (41.3-80.6) | 2 of 3 |
| 1,500 (two sets, 6 runs) | 0.58 | 56.9 (48.1-81.7) | 1 of 6 |
| 1,750 | 0.61 | 87.9 (68.3-98.3) | 0 of 3 |
| 2,000 | 0.94 | 126.9 (95.7-187.5) | 0 of 3 |

On this day the goal held in every run at **1,250 asked**, in two of three at 1,375 and in one of six at 1,500 (against 3,000 on 30/10) while the maximum throughput fell by a
quarter: the capacity at a latency goal fell by more than half. The 3,000-4,000 interval of 30/10 cannot be resolved with this day's machine; repeat `make m01-finer` on a day the 3,000
anchor passes again.

## What this proves
- The ceiling of this configuration is **about 3,900–4,000 req/s**. Past it, asking for more does not get more work
  done; latency for everyone rises by two orders of magnitude and requests queue (k6 cannot even send them).
- The tail breaks first: at 2,000 req/s the typical request is unchanged (0.44 ms) while p99 is already ~33× higher.
- The average hides the tail: at 3,000 req/s p99 is ~8.5× the average.

## What it does not prove
- Nothing about other hardware: compare **ratios** with your own calibration run, not absolute numbers.
- p99 below the ceiling varies ±30–40% between runs on a shared host; treat single-run p99 values as indicative.
- One app instance and one database on the same host; no network latency between them.

## History
- First single run (28/10, `results/first-run/`) was used for the first video cut: its 2,000 req/s p99 (27 ms) and
  4,000 req/s p50 (92 ms) fall outside the 3-run ranges above. Videos must use the numbers in `results.json`.
- An earlier attempt measured k6 itself (k6 at 100% of 1 core, app at 60%): the reason k6 now gets 2 cores.
