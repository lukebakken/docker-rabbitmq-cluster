SHELL := bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c
.DELETE_ON_ERROR:

.PHONY: clean down up perms rmq-perms load status wait-healthy rebalance restart-loop repro

DOCKER_FRESH ?= false
RABBITMQ_DOCKER_TAG ?= rabbitmq:3.13.7-management

# --- #11495 reproduction knobs -------------------------------------------
# Exported so scripts/repro-lib.sh sees them; the lib mirrors each default.
export HOST               ?= 127.0.0.1
export RMQ_USER           ?= guest
export RMQ_PASS           ?= guest
export NODES              ?= rmq0 rmq1 rmq2
export MGMT_PORTS         ?= 8872 8873 8874
export DEFINITIONS        ?= definitions.json
# RESTART_MODE: drain = AMQ graceful (upgrade drain/revive); node = abrupt restart; app = stop_app/start_app
export RESTART_MODE       ?= drain
# RESTART_ITERATIONS: rolling passes; #11495 strands "around the 20th"
export RESTART_ITERATIONS ?= 25
# LIVE_ATTEMPTS x2s = up to 120s for a node to answer the API after `make up`
export LIVE_ATTEMPTS      ?= 60
# HEALTH_ATTEMPTS x2s = up to 240s to reach 3/3 nodes + no alarms
export HEALTH_ATTEMPTS    ?= 120
# LINK_ATTEMPTS x3s = up to 120s for links to return to baseline
export LINK_ATTEMPTS      ?= 40
# REBALANCE_ATTEMPTS x5s = up to 300s for leaders to converge after a rebalance
export REBALANCE_ATTEMPTS ?= 60

clean: perms
	git clean -xffd

down:
	docker compose down

up: rmq-perms
ifeq ($(DOCKER_FRESH),true)
	docker compose build --no-cache --pull --build-arg RABBITMQ_DOCKER_TAG=$(RABBITMQ_DOCKER_TAG)
	docker compose up --pull always --detach
else
	docker compose build --build-arg RABBITMQ_DOCKER_TAG=$(RABBITMQ_DOCKER_TAG)
	docker compose up --detach
endif

perms:
	sudo chown -R "$$(id -u):$$(id -g)" data log

rmq-perms:
	sudo chown -R '999:999' data log

# Import the scrubbed topology and rebalance leaders off the import node.
load:
	@source scripts/repro-lib.sh && do_load

# Report topology + federation roster counts (no entity names).
status:
	@source scripts/repro-lib.sh && print_status

# Block until the cluster is healthy: 3/3 nodes running and no resource alarms.
wait-healthy:
	@source scripts/repro-lib.sh && wait_healthy

# Spread queue leaders evenly across nodes (definitions import lands them all on
# the import node). Async endpoint; blocks until the distribution converges.
rebalance:
	@source scripts/repro-lib.sh && rebalance && print_status

# Rolling-restart the cluster, exiting non-zero the first pass the federation
# roster fails to return to baseline -- that is the #11495 stranding.
restart-loop:
	@source scripts/repro-lib.sh && restart_loop

# Convenience: load then run the restart loop (cluster must already be 'up').
repro: load restart-loop
