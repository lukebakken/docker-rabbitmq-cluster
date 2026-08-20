.PHONY: clean down up perms rmq-perms enable-ff inject inject-periodic clear capture

DOCKER_FRESH ?= false
RABBITMQ_DOCKER_TAG ?= rabbitmq:3.13.7-management

# Failure-detector experiment knobs (see README).
NODE ?= rmq0
LOSS ?= 48
ON ?= 5
OFF ?= 10
SECS ?= 600
INTERVAL ?= 1

clean: perms
	git clean -xffd

down:
	docker compose down

up: rmq-perms
ifeq ($(DOCKER_FRESH),true)
	docker compose build --no-cache --pull --build-arg RABBITMQ_DOCKER_TAG=$(RABBITMQ_DOCKER_TAG)
	docker compose up --pull always
else
	docker compose build --build-arg RABBITMQ_DOCKER_TAG=$(RABBITMQ_DOCKER_TAG)
	docker compose up
endif

perms:
	sudo chown -R "$$(id -u):$$(id -g)" data log

rmq-perms:
	sudo chown -R '999:999' data log

enable-ff:
	docker compose exec rmq0 rabbitmqctl enable_feature_flag all

inject:
	./netem/loss.sh $(NODE) $(LOSS)

inject-periodic:
	./netem/loss-periodic.sh $(NODE) $(LOSS) $(ON) $(OFF)

clear:
	./netem/clear.sh $(NODE)

capture:
	./netem/capture-aten.sh $(SECS) $(INTERVAL)
