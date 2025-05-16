.PHONY: clean down up perms rmq-perms enable-ff import

DOCKER_FRESH ?= false
RABBITMQ_DOCKER_TAG ?= rabbitmq:3.13.7-management

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
	docker compose exec rmq-us rabbitmqctl enable_feature_flag all
	docker compose exec rmq-ds rabbitmqctl enable_feature_flag all

import:
	/bin/sh $(CURDIR)/import-defs.sh
