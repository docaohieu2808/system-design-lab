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

### Retry storm (40 creates/s; the app is stopped from about 11 s to about 22 s; up to 5 retries)
Three arms, interleaved inside every run (order rotated from run to run), 3 runs, `tools/run-m10-storm.sh 3`
(`make m10 RETRY=backoff-nojitter`). Mean (min-max). Quiet-machine gate before every arm: 7-15% background busy,
steal 0. k6 used 0.12-0.14 of its 2 cores and the app 0.02-0.03 of its core, so the load generator had room.

| | attempts during (10-20 s) | attempts after (20-30 s) | gave up, whole run (of 1,200) | busiest second after the app is back | busiest second overall | created after (of ~400) |
|---|---|---|---|---|---|---|
| retry at once | 2,163 (2,111-2,211) | 705 (581-768) | 395 (329-435) | 98 (40-213) | 883 (834-940) | 353 (327-401) |
| backoff + jitter (200 ms, 400 ms, ... x0.5-1.5) | 1,836 (1,476-2,028) | 559 (522-593) | 131 (36-178) | 139 (125-164) | 250 (226-299) | 400 (400-400) |
| backoff, same waits, no jitter | 1,830 (1,611-1,959) | 574 (476-631) | 177 (133-217) | 185 (157-225) | 214 (187-230) | 401 (401-401) |

Normal is 400 attempts per 10 s (40 per second). The app was stopped 10.9 s after k6 started and came back at 21.6-21.9 s,
so the last 1.6-1.9 s of the outage fall in the "after" slice. All three arms share that timing, so compare them with each other.
The "busiest second after the app is back" starts at the first whole second after the app was started again.

What the new no-jitter arm shows:
- Without jitter the busiest second after the app returns is about 1.3 times the busiest second with jitter (185 against 139
  attempts), 4.6 times the normal 40. The ranges touch (157-225 against 125-164), so with 3 runs this is a modest, not a sharp, difference.
- Without jitter more people gave up over the run: 177 against 131; the ranges overlap (133-217 against 36-178), so this is not
  established either. The jitter arm's gave-up count varied a lot from run to run (36 to 178).
- The retry wave is not one big spike in either arm, because arrivals are steady at 40 per second: retries start from every second of
  the outage, so exact waits line up only among requests that failed in the same instant. A visible synchronized spike would need
  a burst of failures at once (for example many clients disconnected together); this test does not make one.
- Retrying at once is a different case: its busiest second is during the outage (883, 22 times normal), and after the app is back
  the retries have already been used up (98).

The earlier table (immediate and backoff measured one after the other in a first run, before this one; the runner then did not record when the app
stopped and returned) read: retry at once 2,137 during, 890 after, 445 gave up, 303 of 400 created after; backoff + jitter
1,941 during, 737 after, 205 gave up, 401 of 401 created after. The pattern is the same as in the interleaved run above: both make about
five times the normal attempts while the app is down and retrying at once gives up far more.

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
