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
m07:           ## Module 7: partitioning, 3 experiments ($(RUNS) runs, about 15 minutes)
	tools/run-m07.sh $(RUNS)
m08:           ## Module 8: CAP, cut the network ($(RUNS) runs, about 5 minutes)
	tools/run-m08.sh $(RUNS)
m09:           ## Module 9: rate limiting, 4 experiments ($(RUNS) runs, about 25 minutes)
	tools/run-m09.sh $(RUNS)
m10:           ## Module 10: async work, 5 experiments ($(RUNS) runs, about 25 minutes)
	tools/run-m10.sh $(RUNS)
m11:           ## Module 11: overload, 2 experiments ($(RUNS) runs, about 20 minutes)
	tools/run-m11.sh $(RUNS)
m12:           ## Module 12: the ticket race ($(RUNS) runs, about 3 minutes)
	tools/run-m12.sh $(RUNS)
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
.PHONY: up down calibrate m00 m01 m03 m04 m05 m06 m07 m08 m09 m10 m11 m12 m13 check-capstone m01-starved verify help
