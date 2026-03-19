.PHONY: clean down up perms rmq-perms enable-ff run-publisher run-consumer use-fixed use-broken run-publisher-dlx run-consumer-dlx

DOCKER_FRESH ?= false
RABBITMQ_DOCKER_TAG ?= rabbitmq:3.13-management

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

amqplib-client/node_modules/.package-lock.json: amqplib-client/package.json
	cd amqplib-client && npm install

run-publisher: amqplib-client/node_modules/.package-lock.json
	node amqplib-client/publisher.js

run-consumer: amqplib-client/node_modules/.package-lock.json
	node amqplib-client/consumer.js

use-fixed:
	cp amqplib-client/package.fixed.json amqplib-client/package.json
	rm -f amqplib-client/node_modules/.package-lock.json

use-broken:
	git checkout amqplib-client/package.json
	rm -f amqplib-client/node_modules/.package-lock.json

run-publisher-dlx: amqplib-client/node_modules/.package-lock.json
	node amqplib-client/publisher-dlx.js

run-consumer-dlx: amqplib-client/node_modules/.package-lock.json
	node amqplib-client/consumer-dlx.js
