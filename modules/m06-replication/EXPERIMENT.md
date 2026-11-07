# Module 6 — replication and failover

## Questions
How often does a read from a replica miss a write that just happened? Does sending fresh readers to the primary fix
it? When the primary is killed, how long are writes down (RTO) and is any confirmed write lost (RPO)?

## Environment
Postgres 18.6 primary + streaming replica (half a core each) on the same 4-vCPU AMD EPYC-Milan host, one app copy,
30/10/2026. `make m06` / `tools/run-m06.sh`, 3 runs of everything.

## Method
1. read-your-writes: k6 creates a link (primary) then opens it at once (replica), 1,500 times; no added lag, then the
   replica applying changes 500 ms late (`recovery_min_apply_delay`), then that lag with `RYW_SECONDS=2` (a cookie sends
   fresh readers to the primary).
2. failover: the app writes `fo-N` links at 100/s for 40 s; at 15 s `docker kill` the primary, 5 s later
   `pg_promote()` the replica. RTO = gap with no successful write; RPO = confirmed codes missing on the new primary.
   Async replication vs synchronous (`remote_apply`).

## Results (mean of 3 runs; `results/results.json`)
| test | result |
|---|---|
| fresh open on replica, no added lag | 75% not found |
| fresh open on replica, 500 ms lag | 100% not found |
| same lag, read-your-writes cookie | 0% not found |
| failover async | RTO 5.6 s, 3,437 confirmed, 0 lost, 0 present without an ok |
| failover sync | RTO 5.6 s, 3,429 confirmed, 0 lost; 1 row present without an ok in one of 3 runs (an ambiguous commit: committed, but the client saw an error) |

## What it shows
- A replica a few milliseconds behind already misses most reads that follow a write immediately.
- Routing a user's own fresh reads to the primary removes the problem for that user.
- RTO here is mostly the 5 s promotion delay we chose (standing in for failure detection).

## What it does not show
- Data loss with async replication: on one machine the replica is milliseconds behind, so nothing confirmed was lost.
- The write-time cost of synchronous replication in the failover run above: write latency was not recorded there; it is measured separately below (added 07/11/2026).
- Automatic failover tools, fencing the old primary, or replicas in another region.

## Added 07/11/2026: what a create costs, asynchronous vs synchronous (`make m06-synccost`, `results-sync-cost/results.json`)
**Question.** What does `synchronous_commit = remote_apply` with the standby named in `synchronous_standby_names = '*'` add to the time of a create, and what do
creates do when that standby is stopped?
**Method.** `tools/run-m06-synccost.sh` and `create-latency.js`: open model, `POST /api/links` at a fixed **200 creates/s** for 30 s after a 5 s warm-up at the same rate,
fresh stack (primary + one streaming replica, half a core each, app half a core, Postgres 18.6, same host as above) and quiet gate 25/2 before every arm (background
10-17% busy, steal 0), k6 niced. 3 runs, the two arms interleaved (order rotating). The synchronous settings are applied after the replica is attached, as in the failover run.
200/s was picked from a one-run probe at 100 / 200 / 400 / 800 per second (`probe-*.json`): both arms answered every create at 200/s and 400/s, nothing dropped.

| arm (3 runs, mean, min-max) | succeeded/s | p50 ms | p99 ms | average ms |
|---|---|---|---|---|
| asynchronous | 200 (200-200) | 1.61 (1.57-1.64) | 24.0 (15.5-31.3) | 2.44 (2.16-2.65) |
| synchronous, remote_apply | 200 (200-200) | 2.26 (2.25-2.28) | 20.1 (19.5-21.0) | 2.98 (2.95-3.02) |

Dropped arrivals 0, failed creates 0 in all six runs. The typical create takes about **0.65 ms longer (+40%)** with the synchronous standby; p99 does not separate (its spread in
the asynchronous arm, 15.5-31.3 ms, covers the synchronous arm's). Primary 0.15-0.16 cores, replica 0.09, app 0.17-0.18 in both arms. Near the limit the price grows: one probe run at 800/s
(single run per arm, not repeated) gave p50 1.7 vs 10.5 ms and p99 77 vs 202 ms, both answering all 800/s.

**Standby stopped (`stopped-1.json`, ONE run, not repeated).** Synchronous settings on, the standby container stopped before the load, 200 creates/s for 20 s, client timeout 5 s:
**0 of 4,001 creates succeeded**, all 4,001 timed out; one create with a 30 s timeout did not come back either. Right after the load the primary held 178 rows from this load
that clients never got an answer for (the commit is local first, and the backend then waits for the standby; the client's timeout cancelled the wait): a timed-out create is
not a failed create.

**Limits.** Primary and replica share one host and one network namespace, so this is the cheapest the wait can be; a replica in another zone adds its round trip to every create.
One create per transaction, no batching. One rate (200/s). The stopped-standby case is a single run.

---

# Module 6, read scaling: does a replica raise the read ceiling?

## Question
What is the highest rate of reads `GET /{code}` (expected 302) that the stack sustains when reads go to the primary
alone, and when they go to the replica `db2`? "Sustains" = succeeded req/s within 1% of the asked rate and 0 dropped
iterations.

## Environment
Same stack as above on the 4-vCPU AMD EPYC-Milan host, 6/11/2026: app half a core, primary half a core, replica half
a core (the M6 limits), one app copy, Postgres 18.6, 100,000 links. k6 limited to 2 cores, 2 GB (the overlay
`compose.reads.yaml` raises k6's memory from 1 GB so an overloaded step is not OOM-killed; no run was).
`make m06-reads` / `tools/run-m06-reads.sh`, 3 runs, all arms interleaved in each run (A B C D E, A B C D E, ...),
fresh stack and quiet gate (`tools/quiet-gate.sh 25 2`) before every ladder. Background busy CPU the gate saw: 7-18%,
steal 0%.

## Method
The lesson 1.1 ladder (`modules/m01-one-server/find-the-ceiling.js`, already reads only, random short link out of
100,000), open model, 20 s per step, 5 s gap. Steps are 250 req/s apart for the half-core arms (1,750 to 3,500) and
500 to 1,000 apart for the 1-core arms (2,000 to 8,000). Per-second CPU and throttling of every `sdlab-*` container and
of the host come from cgroup counters (`tools/cpu-sampler.py`).

| arm | reads go to | app CPU limit |
|---|---|---|
| A | the primary alone (`READ_DATABASE_URL=` empty, no replica pool) | 0.5 core |
| B | the replica db2 (the M6 default) | 0.5 core |
| C | the replica db2 | 1.0 core |
| D | the primary alone | 1.0 core (C's control) |
| E | half to the primary, half to the replica, at random (`READ_SPREAD=1`) | 1.0 core |

A and B are the question. C, D and E were added because the first look showed the app, not the database, is the limit
at the lab's half-core settings (see below).

## Results (3 runs; `results-reads/results.json`; mean, min-max)
| arm | highest sustained rate (req/s, per run) | most req/s served at any step (saturation) |
|---|---|---|
| A primary alone, app 0.5 | 2,750 (2,750 / 2,750 / 2,750) | 3,172 (3,137-3,198) |
| B replica, app 0.5 | 2,583 (2,500 / 2,750 / 2,500) | 3,160 (3,115-3,195) |
| C replica, app 1.0 | 2,833 (3,000 / 2,500 / 3,000) | 3,799 (3,772-3,823) |
| D primary alone, app 1.0 | 3,000 (3,000 / 3,000 / 3,000) | 3,831 (3,798-3,875) |
| E split over both, app 1.0 | 3,167 (3,000 / 3,500 / 3,000) | 5,904 (5,833-5,972) |

CPU near the limit (% of one core; throttled = share of time held back by the CPU limit), from the step just above each
arm's ceiling:

| arm (asked rate) | app | primary | replica | k6 (of 200) |
|---|---|---|---|---|
| A (3,000) | 49.7, throttled 83% | 42, throttled 15% | 2 | 81 |
| B (3,000) | 49.7, throttled 82% | 2.6 | 42, throttled 20% | 79 |
| C (4,000) | 65, throttled under 1% | 2.5 | 50, throttled 113% | 103 |
| D (4,000) | 63, throttled under 1% | 50, throttled 110% | 2.4 | 99 |
| E (6,000) | 83, throttled 3% | 39, throttled 11% | 39, throttled 8% | 125 |

The sustained rate moves in steps of 250-500 req/s and one dropped request fails a step, so it differs between runs by
up to one step; the saturation column (spread under 3% for every arm) is the steadier number for comparing arms.

## What it shows
- Reads on the replica sustain about the same rate as reads on the primary alone: about 2,750 vs about 2,600 req/s
  (A vs B), and the same saturation, about 3,170 req/s. The difference is inside one ladder step. At the lab's limits
  the **app** hits its half-core limit first (throttled about 80% of the time at 3,000 req/s), the database is behind it
  (about 42% of its 50%), so moving the database work to another machine cannot raise the rate.
- Giving the app a full core (C, D) lifts the ceiling to about 3,800 req/s and now the **database** is the limit: the one
  database that serves the reads sits at its half-core cap, throttled for about the whole second. Which database it is
  makes no difference: primary alone (D) and replica alone (C) saturate at the same rate (3,831 vs 3,799). The replica
  is the same size as the primary, so moving all reads from one to the other trades one half core for another.
  The primary is idle in C, which frees it for writes; it adds no read capacity.
- Reads split over both databases (E) lift the saturation to about 5,900 req/s, 1.5 times D's, with neither database at
  its cap (about 39% of 50% each). That is the case where a replica adds read capacity: when reads are spread so
  that both databases work, and the app can feed them.

## What it does not show
- E's limit is not a database or the app limit: at 7,000-8,000 req/s the host is 90% busy (k6 about 1.4 of its 2 cores,
  app 0.8, databases 0.4 each, plus the kernel's network work), so about 5,900 is what this 4-vCPU machine can do with
  this load generator on it, not the ceiling of the design. The sustained-rate column for E (3,167) is low because
  0.8-1.5% of requests were dropped at 3,500-4,000 req/s while the answers still came at 100-130 ms p99; it is a
  strict test and not a limit.
- The two databases are the same size and on the same host. A replica in another zone, with network cost, or a bigger or
  smaller replica would give other numbers.
- Replica reads can be stale (see the first part). This experiment reads 100,000 links that were all there at start, so
  staleness never shows here.
- Writes were not running. Reads and writes together on the primary would show the replica freeing the primary of read
  work, which this test does not measure.
- A and B were measured up to 3,500 req/s only; the app's limit made higher steps pointless there.

## Notes
- k6 had room: it is limited to 2 cores (200%) and used about 80% of one core at A and B's ceiling and at most 143% at E's
  last steps; no run was OOM-killed (k6 exit 0 in all 15).
- `READ_SPREAD=1` is a small addition to `app/replica.go` (random choice between the two pools); default off, other modules
  unchanged. Both pools use the same default connection count.
- A first attempt of this run was stopped after its first pass (the 1-core arms started at 3,000 req/s, above their
  ceiling) and its files were deleted; the ladders above are the ones measured.

---

# Module 6, variations: 50 ms lag, a window shorter than the lag, faster promotion

`make m06-extras` / `tools/run-m06-extras.sh`, 3 runs, arms interleaved (lag50, edge, promote2 in each run), fresh stack
and quiet gate before each (background busy CPU 7-17%, steal 0%), same host and limits as above, 6/11/2026.
Results: `results-extras/results.json` (mean, min-max).

| variation | setting | result |
|---|---|---|
| replica 50 ms late, no read-your-writes | `APPLY_DELAY=50ms`, create then open at once, 50/s for 30 s | 99.96% not found (99.87-100); 1,500 of 1,501 opens |
| window shorter than the lag | `APPLY_DELAY=1500ms RYW_SECONDS=1 READ_DELAY=1.2` (open waits 1.2 s after the create) | 100% not found (100-100) |
| failover, promoted 2 s after the kill | async, `pg_promote()` at +2 s instead of +5 s | RTO 2.75 s (2.70-2.80); 0 confirmed writes lost; 3,705 confirmed (3,699-3,709) |

## What it shows
- A replica only 50 ms behind misses essentially every fresh open when the open follows the create within milliseconds
  (the earlier no-added-lag run missed 75%); a small lag is enough, the open is just faster than it.
- A read-your-writes window only helps while it is open: with a 1 s window, a read 1.2 s after the write goes to the replica,
  which is 1.5 s behind, so every such read misses. The window has to be longer than the lag (the fix from the first part,
  a 2 s window, works because 2 s is longer than 0.5 s).
- RTO follows the promotion timer: 5 s of waiting gave 5.6 s down (first part), 2 s gave 2.75 s. Both runs add about
  0.6-0.75 s on top of the timer; the cause was not traced (the app's 1 s connect timeout is the likely part).

## What it does not show
- The 1.2 s wait is one point between the window and the lag; it shows the edge exists, not how wide it is.
- Real failure detection takes time too; the timer here is a stand-in for it, and the replica is only milliseconds behind,
  so nothing confirmed was lost.
