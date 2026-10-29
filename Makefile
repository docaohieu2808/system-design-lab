# System Design Lab — every number in the course comes from these targets.
RUNS ?= 3

up:            ## start app + Postgres
	docker compose up -d --build --wait
down:          ## stop and remove everything
	docker compose down -v
m00:           ## Module 0: closed vs open load model around a 2-second freeze ($(RUNS) runs, ~5 min each)
	tools/run-omission.sh $(RUNS)
m01:           ## Module 1: find the ceiling of one server ($(RUNS) runs, ~4 min each)
	tools/run-experiment.sh modules/m01-one-server/find-the-ceiling.js $(RUNS)
m01-starved:   ## Module 1: the same test with k6 squeezed to 1 core, to see the load generator lie
	K6_CPUS=1.0 OUT=modules/m01-one-server/results-k6-1core tools/run-experiment.sh modules/m01-one-server/find-the-ceiling.js $(RUNS)
m03:           ## Module 3: load balancing, 4 experiments ($(RUNS) runs, about an hour)
	tools/run-m03.sh $(RUNS)
m04:           ## Module 4: caching, 3 experiments ($(RUNS) runs, about 35 minutes)
	tools/run-m04.sh $(RUNS)
m05:           ## Module 5: database, 5 experiments ($(RUNS) runs, about 40 minutes)
	tools/run-m05.sh $(RUNS)
m06:           ## Module 6: replication, 2 experiments ($(RUNS) runs, about 25 minutes)
	tools/run-m06.sh $(RUNS)
calibrate:     ## ~2 minutes: this machine's ceiling vs the course machine, as a ratio
	tools/calibrate.sh
verify:        ## short self-check: the lab runs, answers are correct, k6 is not saturated
	tools/verify.sh
help:
	@grep -E '^[a-z0-9]+:.*##' Makefile | sed 's/:.*##/ —/'
.PHONY: up down calibrate m00 m01 m03 m04 m05 m06 m01-starved verify help
