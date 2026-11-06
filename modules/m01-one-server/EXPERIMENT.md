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
