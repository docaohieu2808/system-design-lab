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
(`make m10 RETRY=backoff-nojitter`). Mean (min-max). Quiet-machine gate before every arm: 7-24% background busy, steal 0.
k6 used 0.12-0.14 of its 2 cores and the app 0.02-0.03 of its core. Every arrival is now counted: arrivals that began = created + gave up in
all 27 slices (the counting fix below).

| | attempts during (10-20 s) | attempts after (20-30 s) | gave up, whole run (of 1,200) | created after (of 401) | busiest second after the app is back | busiest second overall |
|---|---|---|---|---|---|---|
| retry at once | 2,268 (2,103-2,361) | 573 (491-621) | 391 (309-433) | 373 (357-401) | 96 (40-209) | 686 (261-900) |
| backoff + jitter (200 ms, 400 ms, ... x0.5-1.5) | 2,247 (2,239-2,253) | 485 (480-489) | 180 (171-191) | 401 (400-401) | 128 (105-173) | 245 (240-250) |
| backoff, same waits, no jitter | 2,282 (2,253-2,338) | 560 (488-697) | 171 (46-283) | 401 (401-401) | 160 (103-256) | 285 (243-357) |

During the outage, arrivals (401) end as: retry at once 38 created, 363 gave up; backoff + jitter 221 created, 180 gave up; no jitter 230 created, 171 gave up (each slice's 401 arrivals add up).

Normal is 400 attempts per 10 s (40 per second). The app was stopped about 10.9 s after k6 started and came back at about 21.7 s,
so the last 1.7 s of the outage fall in the "after" slice. All three arms share that timing, so compare them with each other.
The "busiest second after the app is back" starts at the first whole second after the app was started again.

What it shows:
- All three arms make about 5.6 times the normal attempts while the app is down (2,247-2,282 against 400): every arrival is allowed the same five retries, and a 10 s outage outlasts the whole backoff schedule.
  Backoff does not cut the attempts; it spreads them and saves the people: 171-180 give up against 391 with retry at once, and every arrival after the 20 s mark is created.
- Jitter against no jitter: the busiest second after the app returns is 160 (103-256) without and 128 (105-173) with, about 1.25 times, and the ranges overlap; the people who gave up are the same (171 against 180).
  With steady arrivals, 3 runs do not show jitter making a difference. The no-jitter arm is the one with the widest spread (46 to 283 gave up).
- A synchronized wave needs a burst of failures at the same instant. With arrivals spread evenly, retries start from every second of the outage, so exact waits line up only among requests that failed together; this test does not make that burst.
- Retrying at once is a different case: its busiest second is during the outage (686 on average, up to 900 in a run, 17-22 times normal), and after the app is back
  the retries have already been used up (96).

**A counting bug, found and fixed (06/11).** The first interleaved storm run (commit ec620ab) gave backoff arms numbers that did not add up: in the backoff + jitter arm 26, 80 and 29 of the
401 arrivals in the outage slice ended as neither created nor gave up. Cause: k6 had 200 virtual users ready for each phase, and a client that waits and retries keeps its user busy for
seconds, so during the outage the backoff arms needed about 265 at once. k6 started more users while running and, while it did, skipped the arrivals it could not serve (`dropped_iterations`):
a diagnostic run with 200 ready users began only 335 and 331 of 401 arrivals in that slice; with 600 ready users all 401 began, and every slice adds up. The retry-at-once arm
holds its users for milliseconds, so it never hit the limit. Those backoff runs therefore sent fewer attempts than the clients would have (1,836 and 1,830 attempts during the outage; the corrected value
is about 2,250), and the earlier "backoff uses fewer attempts" reading was an artefact. `create.js` now has `PREALLOC` (default 600) and counts, per slice, how many arrivals began, how many were dropped and how many ended neither
created nor gave up (`ended_other`; 0 in all 27 slices here). The earlier gave-up values (131 and 177) and peaks (139 and 185) are replaced by the table above.
The 2-retry arms in "Extra variations" keep a user busy for about a second at most (40 per second needs about 40 users), so I expect them not to be affected; they were not re-run.

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

## Extra variations (`tools/run-m10-extras.sh`, `results-extras/`)
Interleaved inside every run, 3 runs, gate before every arm (background 10-17% busy, steal 0). Mean (min-max). `make m10-extras` (about 75 minutes).

| experiment | arm | result |
|---|---|---|
| side work 400 ms, 40 creates/s | inline: create p50 / p99 | 403 / 409 ms (403-403 / 409-410) |
| | queued: create p50 / p99 | 3 / 9 ms (3-3 / 8-11) |
| workers, jobs done after 40 s (of about 1,200) | 1 worker | 196 (195-197), wait p50 17.2 s, p99 34.0 s |
| | 4 workers | 781 (776-784), wait p50 9.8 s (9.8-9.8), p99 19.5 s (19.4-19.6) |
| | 8 workers | 1,203 (1,202-1,203), wait p50 109 ms (92-122), p99 246 ms (219-277) |
| | 16 workers | 1,203, wait p50 0 ms, p99 2 ms |
| crash 30% in 1,000 payments | no key: charges / double charges | 1,432 (1,429-1,434) / 432 (429-434) |
| | idempotency key: charges / double charges | 1,000 / 0 (the worker crashed 401 times (398-404)) |
| poison job, 200 good jobs behind it | parked after 3 tries | 200 good done in 10 s; 3 tries of the bad job |
| | parked after 30 tries | 200 good done in 10 s; 30 tries of the bad job |
| retry storm, only 2 retries | retry at once: attempts during / after, gave up, created after | 1,114 (1,111-1,117) / 554 (549-562), 433 (430-439), 324 (319-327) of ~400 |
| | backoff + jitter: attempts during / after, gave up, created after | 1,108 (1,100-1,113) / 536 (518-548), 370 (296-410), 366 (347-401) of ~400 |

What it shows:
- With 400 ms of side work the create takes 403 ms inline against 3 ms queued: the whole side-work time comes back out of the request. The jobs still cost 400 ms each; they moved to the worker.
- Throughput scales with workers until the work is done: one job takes 200 ms of side work, so a worker clears 5 a second: 4 workers about 800 in 40 s (781 measured), 8 workers
  clear all 1,200 with a wait of about 0.1 s; going to 16 gains only the last 0.1 s.
- A crash rate of 30% gives about 1 / 0.7 charges per payment: 1,432 charges for 1,000 jobs, 432 of them doubles; the count equals the crashes (432). With a key the table is 1,000 charges and no doubles, even though the
  worker crashed 401 times.
- A poison job costs its tries: the drill has one worker taking jobs in strict order, and every try of the bad job takes about 31 ms (321 tries in 10 s in the main run), so 30 tries hold
  the queue for about 0.9 s and 3 tries for about 0.1 s. Both arms finished all 200 good jobs inside the 10 s window; the delay itself was not timed, the 31 ms per try is taken from the main run.
- With only 2 retries a 10 s outage still outlasts every retry: attempts during the outage are 2.8 times normal (1,114 and 1,108 of 400 normal) against 5.6 times with 5 retries (see the retry storm table above). Backoff
  with 2 retries waits only about 0.6 s in total, so it gives up on many more requests (370, 296-410) than with 5 retries (180, corrected): the extra retries at 5 retries are what let people wait out the end of the outage. 2 retries: about twice as many give up for about half the attempts.
  The busiest second after the app is back is 40 for retry-at-once (nothing left to retry) and 69 (55-96) for backoff.
Not shown: the 5-retry storm arms were not re-run in this run, so compare against the corrected storm table above, which was measured later the same day. The 2-retry arms were not re-run after the counting fix.

## What it does not show
- Queues with several partitions, ordering across them, or exactly-once delivery from the broker.
- Crashes in the middle of a charge, rather than between charging and acknowledging.
