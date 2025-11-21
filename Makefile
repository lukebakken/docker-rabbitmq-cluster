.PHONY: clean down up perms rmq-perms enable-ff run-stream-perf-test

DOCKER_FRESH ?= false
RABBITMQ_DOCKER_TAG ?= rabbitmq:4-management

clean: perms
	git clean -xffd

down:
	docker compose down

stop-apps:
	docker compose stop dotnet-stream-client-app java-stream-client-app

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

run-java-app:
	$(MAKE) -C $(CURDIR)/java-stream-client-app run

run-dotnet-app:
	$(MAKE) -C $(CURDIR)/dotnet-stream-client-app run

run-stream-perf-test:
	docker run --rm --pull always --network rabbitnet pivotalrabbitmq/stream-perf-test:latest --uris rabbitmq-stream://haproxy:5552 --producers 5 --consumers 5 --rate 1000 --delete-streams --max-age PT30S --load-balancer
