.PHONY: clean down up perms rmq-perms

RABBITMQ_DOCKER_TAG ?= 3-management

clean: perms
	git clean -xffd

down:
	docker compose down

up: rmq-perms
	docker compose build --build-arg RABBITMQ_DOCKER_TAG=$(RABBITMQ_DOCKER_TAG)
	docker compose up

perms:
	sudo chown -R "$(USER):$(USER)" data log

rmq-perms:
	sudo chown -R '999:999' data log
