.PHONY: clean down fresh image-base import up

clean: down
	docker system prune --force

down:
	docker compose down

fresh: down clean up import

image-base:
	docker build --pull --tag rabbitmq-base:latest --file $(CURDIR)/docker/base .

image-vesc-1034:
	docker build --tag vesc-1034:latest --file $(CURDIR)/docker/vesc-1034 .

import:
	/bin/sh $(CURDIR)/import-defs.sh

up:
	docker compose up --detach
