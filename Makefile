.PHONY: clean down fresh image-3.8 image-3.10 import up

clean: down
	sudo chown -R "$(USER):$(USER)" data log
	rm -rf $(CURDIR)/data/*/rabbit*
	rm -rf $(CURDIR)/log/*/*

down:
	docker compose down

fresh: down clean up import

image-3.8:
	docker build --pull --tag rabbitmq-local:latest --build-arg VERSION=3.8-management .

image-3.10:
	docker build --pull --tag rabbitmq-local:latest --build-arg VERSION=3.10-management .

import:
	/bin/sh $(CURDIR)/import-defs.sh

up:
	docker compose up
