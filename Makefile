.PHONY: clean down image-4 import up perms rmq-perms enable-ff

DOCKER_FRESH ?= false
RABBITMQ_DOCKER_TAG ?= rabbitmq:3-management

clean: perms
	git clean -xffd

down:
	docker compose down

image-4:
	docker compose build --no-cache --pull --build-arg RABBITMQ_DOCKER_TAG=rabbitmq:4-management

import:
	$(CURDIR)/import-defs.sh

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

upgrade: image-4
	$(CURDIR)/import-defs.sh
	sleep 5
	$(CURDIR)/upgrade.sh
