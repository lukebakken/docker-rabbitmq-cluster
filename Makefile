.PHONY: clean down image-4 import up perms rmq-perms enable-ff apicall

DOCKER_FRESH ?= false
RABBITMQ_DOCKER_TAG ?= rabbitmq:4.1-management-alpine
RABBITMQ_DELAYED_MESSAGE_PLUGIN_VERSION ?= 4.1.0

apicall:
	curl -u 'guest:guest' localhost:15672/api/exchanges

clean: perms
	git clean -xffd

down:
	docker compose down

up: rmq-perms
ifeq ($(DOCKER_FRESH),true)
	docker compose build --no-cache --pull --build-arg RABBITMQ_DOCKER_TAG=$(RABBITMQ_DOCKER_TAG) --build-arg RABBITMQ_DELAYED_MESSAGE_PLUGIN_VERSION=$(RABBITMQ_DELAYED_MESSAGE_PLUGIN_VERSION)
	docker compose up --pull always
else
	docker compose build --build-arg RABBITMQ_DOCKER_TAG=$(RABBITMQ_DOCKER_TAG) --build-arg RABBITMQ_DELAYED_MESSAGE_PLUGIN_VERSION=$(RABBITMQ_DELAYED_MESSAGE_PLUGIN_VERSION)
	docker compose up
endif

perms:
	sudo chown -R "$$(id -u):$$(id -g)" data log

rmq-perms:
	sudo chown -R '100:101' data log

enable-ff:
	docker compose exec rmq0 rabbitmqctl enable_feature_flag all

upgrade: enable-ff
	docker compose build --no-cache --pull --build-arg RABBITMQ_DOCKER_TAG=rabbitmq:4.2-management-alpine --build-arg RABBITMQ_DELAYED_MESSAGE_PLUGIN_VERSION=4.2.0
	$(CURDIR)/upgrade.sh
