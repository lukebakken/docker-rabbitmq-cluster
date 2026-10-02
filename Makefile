.PHONY: clean down up perms rmq-perms enable-ff watch stop-noconfirm

DOCKER_FRESH ?= false
RABBITMQ_DOCKER_TAG ?= rabbitmq:3.13.7-management
CMQ_FIX ?= false

clean: perms
	git clean -xffd

down:
	docker compose down

up: rmq-perms
ifeq ($(DOCKER_FRESH),true)
	docker compose build --no-cache --pull --build-arg RABBITMQ_DOCKER_TAG=$(RABBITMQ_DOCKER_TAG) --build-arg CMQ_FIX=$(CMQ_FIX)
	docker compose up --pull always
else
	docker compose build --build-arg RABBITMQ_DOCKER_TAG=$(RABBITMQ_DOCKER_TAG) --build-arg CMQ_FIX=$(CMQ_FIX)
	docker compose up
endif

perms:
	sudo chown -R "$$(id -u):$$(id -g)" data log

rmq-perms:
	sudo chown -R '999:999' data log

enable-ff:
	docker compose exec rmq0 rabbitmqctl enable_feature_flag all

watch:
	./scripts/watch-mirrors.sh

stop-noconfirm:
	docker compose stop publisher-noconfirm
