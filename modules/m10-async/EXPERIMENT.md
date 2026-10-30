# Module 10 — async work: queues, retries, idempotency

## Questions
- Creating a link also does 200 ms of side work: what does moving it to a queue do to the create time?
- 40 jobs per second for 30 s: how far behind do 1 and 16 workers fall?
- A payment worker that crashes after charging 10% of the time: how many double charges, without and with an
  idempotency key?
- One job that always fails, in front of 200 good ones: retry forever vs a dead-letter queue after 3 tries?
- The app is down for 10 s: what do instant retries and backoff with jitter do to the load?

## Environment
One app copy (half a core), Postgres 18.6, Redis 8.10.2 streams as the queue, k6 1.8.2, 4-vCPU AMD EPYC-Milan host,
30/10/2026. `make m10`, 3 runs.

## Results (mean of 3 runs, min–max in brackets; `results/results.json`)
| experiment | without | with |
|---|---|---|
| create time p50 / p99, side work inline vs queued | 203 / 206 ms | 2 / 6 ms |
| jobs done after 40 s, 1 vs 16 workers (of about 1,200) | 198 | 1,202 (all) |
| job wait p50, 1 vs 16 workers | 17.2 s | 0 ms |
| double charges in 1,000 payments, no key vs idempotency key | 128 (116–137) | 0 |
| good jobs done in 10 s behind a poison job, retry forever vs dead-letter after 3 | 0 (321 tries of the bad job) | 200 (bad job parked after 3) |

### Retry storm (40 creates/s; the app is stopped from 12 s to about 22 s; up to 5 retries)
| | attempts during (10–20 s) | attempts after (20–30 s) | gave up, whole run | created after |
|---|---|---|---|---|
| retry at once | 2,137 (×5.3 normal) | 890 | 445 of 1,200 | 303 of 400 |
| backoff + jitter (200 ms, 400 ms, ... ×0.5–1.5) | 1,941 (×4.9) | 737 | 205 of 1,200 | 401 of 401 |

Normal is 400 attempts per 10 s. Retrying at once spends all five retries within milliseconds (p99 of a create 5–6 ms,
so failures are instant), so everyone who arrives while the app is down gives up, including the first two seconds
after the 20 s mark before the app is back. Backing off waits 0.2 + 0.4 + ... + 3.2 s, about 6 s in total: people who
arrived in the last few seconds of the outage were still waiting when it came back, and nobody after 20 s gave up.
Both still make about five times the normal attempts while the app is down, because both are allowed the same five
retries; a 10 s outage outlasts the whole backoff schedule. Fewer retries, a longer cap, or a server-side "retry
after" would cut the attempts themselves.

Notes on earlier runs:
- `docker compose pause` froze the app; every attempt hung for the 2 s timeout, no difference between the two.
- `docker compose stop` with k6 defaults: k6 kept the app's old address (DNS cached 5 min) and its open connections,
  so attempts still waited out the 2 s timeout on a dead address (p99 11–12 s); only 33 vs 0 gave up.
- Now: with retries, `create.js` looks the app up on every request and opens a fresh connection, so a stopped app
  fails at once, as it would behind a load balancer. The table is from `tools/run-m10-storm.sh 3` after that change.

## What it does not show
- Queues with several partitions, ordering across them, or exactly-once delivery from the broker.
- Crashes in the middle of a charge, rather than between charging and acknowledging.
