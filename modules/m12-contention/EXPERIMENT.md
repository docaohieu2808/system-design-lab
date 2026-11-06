# Module 12 — contention: the ticket race

## Question
1,000 buyers try to buy one of 100 seats at the same moment. How many orders does each way of selling produce?

## Environment
Postgres 18.6 (half a core), the app's `drill tickets` with 50 database connections, 4-vCPU AMD EPYC-Milan host.
Re-measured 07/11/2026 after a lab fix (below): `make m12 LOCK=redis`, 3 runs, fresh lab and quiet-machine gate before every
drill (background busy 5-10%, steal 0).

**Lab fix, 07/11/2026: a warm-up round.** Before the fix, whichever way ran first in a drill paid for opening the pool's 50
connections and warming the tables: the same conditional update took 1.8 s when it ran first and 0.7 s when it ran second
(first pass of `make m12-tx`, autocommit / transaction arm per run: 1,806 / 1,210, 720 / 2,204, 1,833 / 1,113 ms, the first arm of each run being the slow one; those files were replaced by the re-run). `make m12` always ran "check, then insert" first, so its time (1,901 ms) and its order count (983)
were distorted, and every comparison with it. `drill tickets` now runs one untimed round of the conditional update first
(`WARMUP=0` turns it off). All tables below are from after the fix; the earlier tables are in git history (commits before
07/11/2026).

## Results (mean of 3 runs, min-max; `results/results.json`)
| way | orders (of 100 seats) | oversold | time for 1,000 buyers |
|---|---|---|---|
| check, then insert | 1,000 (1,000-1,000) | 900 | 834 ms (797-889) |
| `SELECT ... FOR UPDATE` on the event row | 100 | 0 | 1,463 ms (1,405-1,535) |
| advisory lock around check + insert | 100 | 0 | 1,147 ms (1,061-1,215) |
| one conditional `UPDATE ... WHERE sold < seats`, then the order insert | 100 | 0 | 775 ms (739-807) |
| lock in Redis (`SET ... NX PX 5000`) | 100 | 0 | 3,515 ms (3,141-3,750) |

**What it shows.** With a warm pool the broken way sells a seat to every one of the 1,000 buyers in all 3 runs: all the checks
run before the first insert lands. The conditional update is correct and as fast as the broken way. The row lock is the slowest
of the database ways (buyers queue on one row for a whole transaction); the advisory lock sits between. The Redis lock is correct
and the slowest by far, about 4.5 times the conditional update: every buyer goes through it one at a time and waiters poll every
20-40 ms. I did not profile where its time goes. The spread of the Redis arm (3,141-3,750) is wider than 10 %; its rank does not
depend on it.

## The same contract: the conditional update inside a transaction (`make m12-tx`, `results-tx/`)
The conditional update above is two autocommit statements: the seat is taken, then the order is inserted. A crash between them
would take a seat without an order; the lock ways do both in one transaction. This arm puts the same UPDATE and INSERT in one
transaction. Both arms in every drill, order alternating per run, 3 runs, warm-up on.

| way | orders | oversold | time for 1,000 buyers |
|---|---|---|---|
| conditional update, two autocommit statements | 100 | 0 | 793 ms (729-842) |
| conditional update and order insert in one transaction | 100 | 0 | 1,174 ms (1,083-1,289) |

**What it shows.** Making the seat and its order commit together costs about half again (the transaction holds the row lock
until the insert commits). With the same crash-safety contract, the conditional update in a transaction is about as fast as the
advisory lock (1,147 ms, ranges overlap) and faster than `FOR UPDATE` (1,463 ms). Spread over 10 % (1,083-1,289); the gap to the
autocommit arm is larger than both ranges.

## Data for course 2.2: a lease that expires mid-work
Same drill, only the lock holders change: the first three holders freeze for 5 s right after their check and before their write,
while the lock lasts 1 s, so it expires, others take it and fill the seats, and each frozen holder then writes with a check that
is out of date. Second arm adds a fencing token (a number that grows with every grant; the database refuses a write whose number is
lower than one it has already seen). 3 runs each.

| arm | orders (of 100 seats) | oversold | time |
|---|---|---|---|
| lock expires mid-work, no token | 103 (103-103) | 3 (3-3) | 7,027 ms (7,006-7,039) |
| lock expires mid-work, with fencing token | 100 (100-100) | 0 | 7,290 ms (7,021-7,595) |

**What it shows.** Three frozen holders gave exactly three extra orders in all 3 runs: each saw room, froze past its lease, and
wrote after the seats were gone. The Redis lock cannot tell the holder its lease ended; the database check with the token can,
and it refused all three late writes (100 orders, 0 oversold). The time is dominated by the 5 s freeze in both arms (the fenced arm
is about 0.3 s slower on average, ranges overlapping; re-measured 07/11/2026 with the warm-up).
**What it does not show.** A real pause (garbage collection, a stopped VM) instead of a sleep; only one Redis (no failover, no Redlock);
the lease and the freeze are chosen to make it happen, not measured from a real system.

## Only 4 database connections (`make m12 POOL_MAX=4`, `results-pool4/`)
Same drill and the same four database ways, but the app's connection pool holds 4 connections instead of 50. 3 runs, warm-up
on, gate before every drill (background busy 5-10%, steal 0). Re-measured 07/11/2026.

| way | orders (of 100 seats) | time for 1,000 buyers |
|---|---|---|
| check, then insert | 1,000 (1,000-1,000), 900 oversold | 500 ms (434-557) |
| `SELECT ... FOR UPDATE` | 100 | 980 ms (921-1,056) |
| advisory lock | 100 | 655 ms (624-672) |
| one conditional `UPDATE` | 100 | 387 ms (381-399) |

What it shows: the broken way oversells the same with 4 connections as with 50 (every buyer gets a seat). The correct ways stay
correct and are faster with 4 connections than with 50 (conditional update 387 against 775 ms; row lock 980 against 1,463 ms),
because fewer connections fight over the same row. A small pool hides nothing: it only changes the time. The spread of the broken
way (434-557) is wider than 10 %; it does not change its rank.

## What it does not show
- Payments failing midway, or seat maps (specific seats).
- Redis failover or Redlock (several Redis nodes); only one Redis.
- Several app copies or databases.
