.PHONY: clean down up perms rmq-perms

RABBITMQ_DOCKER_TAG ?= rabbitmq:3-management

clean: perms
	git clean -xffd

down:
	docker compose down

up: rmq-perms
	# NB: fresh stuffs
	# docker compose build --no-cache --pull --build-arg RABBITMQ_DOCKER_TAG=$(RABBITMQ_DOCKER_TAG)
	# docker compose up --pull always
	docker compose build --no-cache --pull --build-arg RABBITMQ_DOCKER_TAG=$(RABBITMQ_DOCKER_TAG)
	docker compose up --pull always

perms:
	sudo chown -R "$(USER):$(USER)" data log

rmq-perms:
	sudo chown -R '999:999' data log
