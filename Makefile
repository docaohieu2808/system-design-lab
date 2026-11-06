# System Design Lab — every number in the course comes from these targets.
RUNS ?= 3

up:            ## start app + Postgres
	docker compose up -d --build --wait
dash:          ## optional: Grafana dashboard at http://localhost:3000 (measurements run with it off)
	COMPOSE_FILE=compose.yaml:compose.dash.yaml UID=$$(id -u) GID=$$(id -g) docker compose up -d --build --wait
	@echo "Grafana: http://localhost:3000 . Run k6 with the overlay on: export COMPOSE_FILE=compose.yaml:compose.dash.yaml (then your module's overlay) before docker compose run k6 ..."
down:          ## stop and remove everything
	COMPOSE_FILE=compose.yaml:compose.dash.yaml docker compose down -v --remove-orphans
m00:           ## Module 0: closed vs open load model around a 2-second freeze ($(RUNS) runs, ~5 min each)
	tools/run-omission.sh $(RUNS)
m01:           ## Module 1: find the ceiling of one server ($(RUNS) runs, ~4 min each)
	tools/run-experiment.sh modules/m01-one-server/find-the-ceiling.js $(RUNS)
m01-variations: ## Module 1/2: ceiling test with k6 at half a core, and with the app at a whole core, vs base, interleaved ($(RUNS) runs, about 50 minutes)
	tools/run-m01-variations.sh $(RUNS)
m00-closed200: ## Module 0: the 2 s freeze with a closed model of 10 users, 200 users, and an open model ($(RUNS) runs, about 15 minutes)
	tools/run-m00-closed200.sh $(RUNS)
m01-starved:   ## Module 1: the same test with k6 squeezed to 1 core, to see the load generator lie
	K6_CPUS=1.0 OUT=modules/m01-one-server/results-k6-1core tools/run-experiment.sh modules/m01-one-server/find-the-ceiling.js $(RUNS)
m03:           ## Module 3: load balancing, 4 experiments ($(RUNS) runs, about an hour)
	tools/run-m03.sh $(RUNS)
m03-cause:     ## Module 3.1: what limits the 4th copy, 1-4 copies + 3 give-it-more variants ($(RUNS) runs, about 80 minutes)
	tools/run-m03-cause.sh $(RUNS)
m03-health:    ## Module 3.3: shallow vs deep health check when a copy loses its database ($(RUNS) runs, about 15 minutes)
	tools/run-m03-health-lie.sh $(RUNS)
m03-extras:    ## Module 3 extras: split cores, kill at 400, health check 5 s, two slow copies, one slow copy ($(RUNS) runs, about 80 minutes)
	tools/run-m03-extras.sh $(RUNS)
m04:           ## Module 4: caching, part a (hit ratio) + part b (stampede, expiry fixes) ($(RUNS) runs, about 50 minutes)
	tools/run-m04.sh $(RUNS)
	tools/run-m04b.sh $(RUNS)
m04-size:     ## Module 4a: cache-size sweep, Redis 1/2/4/8 MB, Zipf and even keys, interleaved ($(RUNS) runs, about 35 minutes)
	tools/run-m04-size.sh $(RUNS)
m04-extra:    ## Module 4b: stampede with a 1 s build, 100% jitter, jitter + stale-while-revalidate, interleaved with the old arms ($(RUNS) runs, about 45 minutes)
	tools/run-m04b-extra.sh $(RUNS)
m05:           ## Module 5: database, 5 experiments ($(RUNS) runs, about 40 minutes)
	tools/run-m05.sh $(RUNS)
m05-deepen:   ## Module 5 variations: no-index rates, N+1 at 400/s, pool sizes, FOR UPDATE modes, pgbench prepared ($(RUNS) runs, about 90 minutes)
	tools/run-m05-deepen.sh $(RUNS)
m06:           ## Module 6: replication, 2 experiments ($(RUNS) runs, about 25 minutes)
	tools/run-m06.sh $(RUNS)
m06-reads:     ## Module 6: read scaling, primary alone vs replica, 5 arms ($(RUNS) runs, about 80 minutes)
	tools/run-m06-reads.sh $(RUNS)
m06-extras:    ## Module 6: 50 ms lag, window shorter than the lag, promotion after 2 s ($(RUNS) runs, about 15 minutes)
	tools/run-m06-extras.sh $(RUNS)
m07:           ## Module 7: partitioning, 3 experiments ($(RUNS) runs, about 15 minutes)
	tools/run-m07.sh $(RUNS)
m07-hotfix:    ## Module 7.3 fix: even / hot / hot + cache of hot codes, interleaved ($(RUNS) runs, about 10 minutes)
	tools/run-m07-hotfix.sh $(RUNS)
m07-ids:       ## Module 7.4 only: bigint / UUIDv4 / UUIDv7 insert time, table and index size ($(RUNS) runs, about 6 minutes)
	tools/run-m07-ids.sh $(RUNS)
m08:           ## Module 8: CAP, cut the network ($(RUNS) runs, about 5 minutes)
	tools/run-m08.sh $(RUNS)
m09:           ## Module 9: rate limiting, 4 experiments ($(RUNS) runs, about 25 minutes)
	tools/run-m09.sh $(RUNS)
m09-sliding:  ## Module 9.3: sliding-window log + one-copy baseline vs fixed window and token bucket ($(RUNS) runs, about 30 minutes)
	tools/run-m09-sliding.sh $(RUNS)
m10:           ## Module 10: async work, 5 experiments ($(RUNS) runs, about 25 minutes); with RETRY set, only the retry-storm arms (instant, backoff, backoff-nojitter), about 10 minutes
	@if [ -n "$(RETRY)" ]; then tools/run-m10-storm.sh $(RUNS); else tools/run-m10.sh $(RUNS); fi
m10-extras:   ## Module 10 variations: side work 400, 4/8 workers, crash 30%, DLQ after 30, storm with 2 retries ($(RUNS) runs, about 75 minutes)
	tools/run-m10-extras.sh $(RUNS)
m10-burst:    ## Module 10 retry burst: 300 clients fail together, backoff without jitter vs full jitter ($(RUNS) runs, about 6 minutes)
	tools/run-m10-burst.sh $(RUNS)
m11:           ## Module 11: overload, 2 experiments ($(RUNS) runs, about 20 minutes)
	tools/run-m11.sh $(RUNS)
m11-breaker:   ## Module 11.4: no breaker / simple / single-probe breaker, interleaved ($(RUNS) runs, about 12 minutes)
	tools/run-m11-breaker.sh $(RUNS)
m12:           ## Module 12: the ticket race ($(RUNS) runs, about 3 minutes; LOCK=redis adds the Redis lock and the stalled-holder arms, about 10 minutes)
	tools/run-m12.sh $(RUNS)
m12-tx:        ## Module 12: the conditional update with and without a transaction around the order insert ($(RUNS) runs, about 3 minutes)
	tools/run-m12-tx.sh $(RUNS)
m13:           ## Capstone 13.3: news feed fan-out ($(RUNS) runs, about 5 minutes)
	tools/run-m13.sh $(RUNS)
check-capstone: ## capstone 13.1: does your URL shortener meet the contract and the module-two goals?
	tools/check-capstone.sh $(URL)
calibrate:     ## ~2 minutes: this machine's ceiling vs the course machine, as a ratio
	tools/calibrate.sh
verify:        ## short self-check: the lab runs, answers are correct, k6 is not saturated
	tools/verify.sh
help:
	@grep -E '^[a-z0-9]+:.*##' Makefile | sed 's/:.*##/ —/'
.PHONY: dash up down calibrate m00 m01 m03 m03-cause m03-health m03-extras m04 m04-size m04-extra m05 m05-deepen m06 m06-reads m06-extras m07 m07-hotfix m07-ids m08 m09 m09-sliding m10 m10-extras m10-burst m11 m11-breaker m12 m12-tx m13 check-capstone m01-starved m01-variations m00-closed200 verify help
