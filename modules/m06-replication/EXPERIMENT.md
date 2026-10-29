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
| failover async | RTO 5.6 s, 3,437 confirmed, 0 lost |
| failover sync | RTO 5.6 s, 3,429 confirmed, 0 lost |

## What it shows
- A replica a few milliseconds behind already misses most reads that follow a write immediately.
- Routing a user's own fresh reads to the primary removes the problem for that user.
- RTO here is mostly the 5 s promotion delay we chose (standing in for failure detection).

## What it does not show
- Data loss with async replication: on one machine the replica is milliseconds behind, so nothing confirmed was lost.
- The write-time cost of synchronous replication: write latency was not recorded in this run.
- Automatic failover tools, fencing the old primary, or replicas in another region.
