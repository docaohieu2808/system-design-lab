# Module 3 — load balancing

## Questions
Do N app copies behind a load balancer carry N times the traffic? What happens when a copy is killed, frozen, or slow?

## Environment
Module 1's stack plus Traefik v3.7.16 (1 core) in front of N app copies (a quarter of a core each), Postgres half a
core, k6 2 cores. 4-vCPU AMD EPYC-Milan host, 29–30/10/2026. Every request asks for the preview page (`/page/{code}`):
the same lookup as the redirect plus about 0.8 ms of CPU (`PAGE_WORK=6000`), because with the bare redirect the
proxy itself used about as much CPU as the app copies and the 4-core host filled up (first try, see lesson 3.1;
the formal measurement of that is `results-proxy/`).

## Method (`make m03`, `tools/run-m03.sh`, 3 runs of everything)
1. scale: 1–4 copies, step test 150 → 1,350 pages/s, 15 s per step. Ceiling = most pages/s that succeeded.
2. kill: 600 pages/s for 60 s; at 30 s `docker kill` one copy. 3 copies vs 4.
3. pause: 400 pages/s; at 30 s `docker pause` one of 3 copies. Without vs with a Traefik health check (1 s / 500 ms).
4. slow: 400 pages/s over 3 copies, one limited to 0.08 core. Traefik `wrr` (take turns) vs `p2c` (less busy of two).

## Results (mean of 3 runs; `results/results.json`)
| copies | ceiling pages/s (min–max) | peak CPU: Traefik / db (limit 50%) / host |
|---|---|---|
| 1 | 321 (309–342) | 89% / 54% / 99% |
| 2 | 685 (677–693) | 84% / 53% / 96% |
| 3 | 1,063 (1,059–1,070) | 48% / 26% / 69% |
| 4 | 1,270 (1,264–1,278) | 49% / 51% / 79% |

| test | p99 before → after | failed after (of ~12,000–18,000) |
|---|---|---|
| kill, 3 copies | 84 → 518 ms | 106 |
| kill, 4 copies | 74 → 86 ms | 89 |
| freeze, no health check | 66 → 3,001 ms | 3,861 |
| freeze, health check | 68 → 3,000 ms | 191 |
| slow copy, wrr | 3,001 ms (both halves) | 3,085 / 3,500 per half |
| slow copy, p2c | 86 → 87 ms | 0 |

## What it shows
- Copies add capacity nearly in proportion; the 4th copy adds less. The first explanation here, "the database reaches its
  half core (51%)", did not survive the follow-up below: the database sat at 21% of a core (42% of its limit) at the
  4-copy ceiling, and giving it twice the CPU changed nothing. The 51% above was a peak taken on an overloaded step.
- A killed copy loses the requests it held (~100 here) whatever the setup; with no spare the remaining copies run near
  their ceiling and p99 rises about 6×; with a spare p99 barely moves.
- A frozen copy keeps receiving a third of the traffic until something checks it; a 1 s health check cuts failures
  about 20×. p99 stays at the 3 s timeout because ~1.6% of requests still time out before the check acts.
- With one slow copy, taking turns fails about a quarter of requests; picking the less busy of two fails none.

## What it does not show
- Past each ceiling the steps overload k6 and the host (host CPU up to 99% with 1–2 copies); only the rising part of
  each step test is used for the ceiling, and the peak CPU columns include those overloaded steps.
- Several machines, real network latency between them, or Traefik's own failover (one Traefik here).
- Exact numbers for your machine; compare the shape (see Module 0, calibration).

## The proxy's own cost (`tools/run-m03-proxy.sh`, `results-proxy/`)
3 app copies, plain redirect (no page work) at 2,000 req/s for 30 s, 3 runs: all succeeded; Traefik used 61% of a core,
the three app copies 61% together. With a request this cheap the proxy costs as much as the app, which is why the
module uses the preview page.

## What limits the 4th copy (`tools/run-m03-cause.sh`, `results-cause/`)
**Question.** The 4th copy added 213 pages/s where the 3rd added 330. Which part is full at 4 copies?
**Method.** The same step test (150 -> 1,350 pages/s, 15 s per step, `/page/{code}`), 1-4 copies, plus three variants
on 4 copies that each give one suspect more: database 0.5 -> 1.0 core (`db1`), Traefik 1 -> 2 cores (`traefik2`), k6
pinned to CPU 3 alone with everything else on CPUs 0-2 (`k6pin`). Per-second CPU and throttling of every `sdlab-*`
container and of the host (`tools/cpu-sampler.py`), averaged over each step's steady seconds. 3 runs, the 7 arms
interleaved inside each run, machine gate (`tools/quiet-gate.sh 25 2`) before every arm; an arm repeated if the other
containers on the machine used more than 25% of a core. Background CPU seen by the gate: 7-24%.
**Results** (mean, min-max of 3 runs; ceiling = most pages/s that succeeded):

| arm | ceiling pages/s | per copy |
|---|---|---|
| 1 copy | 298 (295-299) | 298 |
| 2 copies | 654 (649-661) | 327 |
| 3 copies | 984 (980-987) | 328 |
| 4 copies (base4) | 1,197 (1,172-1,217) | 299 |
| 4 copies, database 1.0 core | 1,194 (1,183-1,206) | 299 |
| 4 copies, Traefik 2 cores | 1,211 (1,196-1,220) | 303 |
| 4 copies, k6 pinned alone | 1,181 (1,123-1,213) | 295 |

At the top step of the 4-copy arm: each app copy 24.9% of a core (their limit is 25%: 99.6% of it, throttled the whole
time), database 21.1% of a core (20.7-21.6; limit 50%), Traefik 44.3% (39.2-47.6; limit 100%), k6 51.8% of its two
cores (43.6-57.2%, so it had room), the host 80.3% busy (75.9-88.5), other containers on the machine 12.6% of one core.
**What it shows.**
- At every size the app copies are the full part: 24.9-25.6% of a core each, which is their limit, at the ceiling.
  Each page costs the copy about 0.8 ms of CPU in all four sizes (0.84, 0.78, 0.78, 0.83), so the ceiling is about
  300 pages/s per copy times the number of copies.
- Giving the database, Traefik or k6 more room moved the ceiling by less than the spread between runs (1,181-1,211
  against 1,172-1,217 for the plain arm). None of the three was the limit.
- The ceilings here are 7-9% below the table at the top of this file, which was measured on a quieter machine; compare
  arms within this section, not across the two.
**Check for a foreign container.** Another agent ran a `golang` container, without the lab lock, between 12:34:51 and 12:36:09 (Saigon time). The
last cause arm (`traefik2`, run 3) ended at 12:33:48 and every other arm ended earlier, so no cause step overlapped it, and the runner's own
check (all non-lab containers together under 25% of a core during an arm, otherwise the arm is thrown away and repeated) found nothing to
discard. No arm was rerun. The "other containers" reading at the 4-copy top step is 12.6% of one core (8.6-18.1).
**What it does not show.** Why the 3rd to 4th step is smaller than 2nd to 3rd: per copy the ceiling falls from 328 to 299
(9%) while the CPU per page rises only 6%. The host is 74% busy with 3 copies and 80% with 4, with about 0.9 of a core
that no container accounts for (kernel network work, the sampler), and the 4 vCPUs may be hyperthreads that share
cores; I did not isolate this. The throttled column of the sampler adds up all threads of a container, so it can pass
100%. Traefik's CPU reading is missing for the two overloaded top steps of the 1- and 2-copy arms (the sampler lost the
container); those steps are above the ceiling and no number here uses them.

## Health checks that lie (`tools/run-m03-health-lie.sh`, `results-health/`)
**Question.** One of three copies loses its database halfway (its network to Postgres is cut at second 32), but the
process keeps running. Does a health check that only asks "are you alive?" (`/livez`) notice? Does one that touches the
database (`/healthz`) do better?
**Method.** 3 copies (2 good, 1 that reaches the database through its own network, cut at 32 s), a steady 400 pages/s
for 60 s, Traefik check every 1 s with a 500 ms timeout. Three arms interleaved per run: no check, shallow `/livez`,
deep `/healthz`. 3 runs, gate before every arm (background 7-11% busy, steal 0). The "after" phase is the 30 s after the cut.
**Results** (after the cut, mean and min-max of 3 runs, of about 12,000 requests):

| check | failed | p99 | p99 before the cut |
|---|---|---|---|
| none | 3,880 (3,871-3,892) | 3,001 ms | 76 ms |
| shallow `/livez` | 3,888 (3,871-3,920) | 3,001 ms | 76 ms |
| deep `/healthz` | 176 (166-187) | 3,000 ms | 75 ms |

**What it shows.**
- The shallow check changed nothing: 3,888 failures against 3,880 with no check, a third of all requests (one copy of three,
  taking turns). The copy still answers `/livez`, so Traefik keeps it in the pool and every page it gets returns 503.
- The deep check cut failures 22 times. It still lets about 176 through: the 1 s check interval and the timeout before
  the copy is dropped, with about 133 requests/s going to the bad copy.
- p99 is 3,000 ms in all three because it is capped by the 3 s request timeout: more than 1% of requests still failed in
  the window, even for the deep check. Use the failed column, not p99, to compare these.
**What it does not show.** A deep check has its own risk: if the shared database is slow, every copy fails its check at
once and the proxy has nothing left to send to. Here only one copy lost the database, so that case is not tested.

## Extra runs for lessons 3.1-3.4 (`tools/run-m03-extras.sh`, `results-extras/`)
Eight arms in every run, interleaved, 3 runs, gate before every arm (background 11-22% busy, steal 0), k6 limit 3 GB. Mean (min-max).
This machine was busier than for the first table above, so compare arms inside this section.

**Split the cores: 4 copies of 0.25 core against 2 copies of 0.5 core** (step test 150 to 1,350 pages/s):

| | ceiling pages/s | p99 at 450 pages/s | p99 at 900 pages/s |
|---|---|---|---|
| 4 x 0.25 core | 1,194 (1,178-1,215) | 70 ms (69-71) | 160 ms (142-174) |
| 2 x 0.5 core | 1,256 (1,250-1,261) | 17 ms (15-20) | 117 ms (83-167) |

The same total CPU gives 5% more pages/s and a much calmer slow end when it is split into two bigger copies: a page costs about 0.8 ms of CPU,
so a quarter-core copy is cut off by its CPU limit for part of every 100 ms, and a half-core copy waits half as long for the same work. That
explanation comes from how the CPU limit works and from the p99 gap; I did not measure throttling per copy in this run.

**Kill one of 3 copies at 32 s, 400 pages/s:** failed after the kill 95 (65-135) of about 12,000; p99 after the kill 1,083 ms, run by run 2,999, 100 and 150 ms.
The p99 is bimodal because it sits on the 1% line: a run with more than about 120 failures has its p99 at the 3 s timeout, one with fewer does not.
Compare 3 copies at 600 pages/s above (failed 106, p99 518 ms).

**Freeze one of 3 copies at 400 pages/s, health check every 1 s against every 5 s (timeout 500 ms):**

| check interval | failed after the freeze | p99 after |
|---|---|---|
| 1 s | 135 (99-186) | 2,056 ms (169-3,000) |
| 5 s | 488 (450-545) | 3,001 ms |

The 5 s check lets 3.6 times as many requests fail. The worst case, 133 requests a second to the frozen copy for 5.5 s, would be about 730; the
measured 450-545 is below it. The 1 s arm here is lower and less steady than the 190 failures (190-192) of the earlier freeze test; one
run also had 34 failed requests before the freeze that I cannot explain. The check overlay differs only in being a copy of `compose.health.yaml`
with the interval as a variable, and k6 had a 3 GB limit; I did not find which difference moved the number.

**Two slow copies (app-2 and app-3 at 0.08 core), 400 pages/s over 3 copies:**

| strategy | failed (both 30 s halves together) | p99 |
|---|---|---|
| wrr (take turns) | 14,008 of about 24,000 (6,677 in the first 30 s + 7,331 in the second) | 3,004 / 3,019 ms (first / second half) |
| p2c (less busy of two) | 0 | 669 / 833 ms |

(The squeeze is in place before the load starts here, so both halves are the same situation.) Two thirds of the traffic goes to copies that
can do about 85 pages/s each, so taking turns fails over half of everything; picking the less busy of two fails none but p99 is 0.7-0.8 s,
because the one good copy and the two slow ones are all busy.

**One copy at 0.08 core, step test:** the real ceiling is 85 pages/s (85-86), with p99 2.3 s at the step that gave it; at 120 pages/s only 48 succeed (the line grows).
That replaces the earlier assumption of "about 100 a second" (a third of 321).
