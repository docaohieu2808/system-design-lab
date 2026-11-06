# Module 12 — contention: the ticket race

## Question
1,000 buyers try to buy one of 100 seats at the same moment. How many orders does each way of selling produce?

## Environment
Postgres 18.6 (half a core), the app's `drill tickets` with 50 database connections, 4-vCPU AMD EPYC-Milan host,
30/10/2026. `make m12`, 3 runs.

## Results (mean of 3 runs; `results/results.json`)
| way | orders (of 100 seats) | time for 1,000 buyers |
|---|---|---|
| check, then insert | 972 (872 oversold) | 1,502 ms |
| `SELECT ... FOR UPDATE` on the event row | 100 | 1,368 ms |
| advisory lock around check + insert | 100 | 758 ms |
| one conditional `UPDATE ... WHERE sold < capacity` | 100 | 703 ms |

## A lock held in Redis (`make m12 LOCK=redis`, `tools/run-m12.sh`)
**Question.** Does the same race go away if every buyer first takes a lock in Redis (`SET ... NX PX 5000`, released only if it
is still theirs), and what does it cost? **Method.** The same drill with Redis 8.10.2 (0.5 core, nothing saved to disk) added
next to the app; the five ways run one after the other inside the same drill, 3 runs, fresh lab and quiet-machine gate before
every drill (background busy 7-17%, steal 0). This run re-measured all five ways, so its first four rows replace the table
above for comparison; the table above is the earlier run on a quieter day.

| way | orders (of 100 seats) | oversold | time for 1,000 buyers |
|---|---|---|---|
| check, then insert | 983 (968-990) | 883 (868-890) | 1,901 ms (1,886-1,914) |
| `SELECT ... FOR UPDATE` | 100 | 0 | 1,578 ms (1,525-1,620) |
| advisory lock | 100 | 0 | 988 ms (967-1,010) |
| one conditional `UPDATE` | 100 | 0 | 750 ms (696-790) |
| lock in Redis | 100 | 0 | 3,728 ms (3,362-4,101) |

**What it shows.** The Redis lock sells exactly 100 and never oversells here, but it is the slowest of the correct ways: 3.7 s,
5 times the conditional update. Every buyer goes through the lock one at a time and the waiters poll every 20-40 ms; the time is
about 3.7 ms per buyer in turn. I did not profile where the 3.7 ms goes (two Redis round trips and a lock hand-off per buyer are the
likely parts). The app used 0.40 of a core, Postgres 0.31, Redis 0.11, so none of them was full.

## Data for course 2.2: a lease that expires mid-work
Same drill, only the lock holders change: the first three holders freeze for 5 s right after their check and before their write,
while the lock lasts 1 s, so it expires, others take it and fill the seats, and each frozen holder then writes with a check that
is out of date. Second arm adds a fencing token (a number that grows with every grant; the database refuses a write whose number is
lower than one it has already seen). 3 runs each.

| arm | orders (of 100 seats) | oversold | time |
|---|---|---|---|
| lock expires mid-work, no token | 103 (103-103) | 3 (3-3) | 7,059 ms (7,026-7,087) |
| lock expires mid-work, with fencing token | 100 (100-100) | 0 | 7,898 ms (7,653-8,136) |

**What it shows.** Three frozen holders gave exactly three extra orders in all 3 runs: each saw room, froze past its lease, and
wrote after the seats were gone. The Redis lock cannot tell the holder its lease ended; the database check with the token can,
and it refused all three late writes (100 orders, 0 oversold). The time is dominated by the 5 s freeze in both arms (the fenced arm
is 0.8 s slower on average; I did not investigate it, the ranges are separate).
**What it does not show.** A real pause (garbage collection, a stopped VM) instead of a sleep; only one Redis (no failover, no Redlock);
the lease and the freeze are chosen to make it happen, not measured from a real system.

## What it does not show
- Payments failing midway, or seat maps (specific seats).
- Redis failover or Redlock (several Redis nodes); only one Redis.
- Several app copies or databases.
