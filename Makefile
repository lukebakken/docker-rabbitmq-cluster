.PHONY: clean down up upgrade upgrade-from upgrade-image perms rmq-perms enable-ff

DOCKER_FRESH ?= false
COMPOSE_UP_ARGS ?=
RABBITMQ_DOCKER_TAG ?= rabbitmq:4-management

# The upgrade test pins both ends. These stay out of RABBITMQ_DOCKER_TAG so that
# `make up` does not default to the older release and rebuild an
# already-upgraded cluster onto it: the old nodes cannot apply the newer Khepri
# machine version, so they report Up, never become ready, and say so only at
# debug level. Overriding RABBITMQ_DOCKER_TAG with an older tag still can.
RABBITMQ_UPGRADE_FROM_DOCKER_TAG ?= rabbitmq:4.2.9-management
RABBITMQ_UPGRADE_DOCKER_TAG ?= rabbitmq:4.3.6-management

# The version every node must report once the roll finishes, so that a restart
# that upgraded nothing fails instead of printing success.
RABBITMQ_EXPECTED_VERSION ?= $(patsubst %-management,%,$(lastword $(subst :, ,$(RABBITMQ_UPGRADE_DOCKER_TAG))))

# `down` first: `perms` hands the data directories back to the host user and
# `git clean` then unlinks them, which would otherwise happen underneath a
# running cluster.
clean: down perms
	git clean -xffd

down:
	docker compose down

up: rmq-perms
ifeq ($(DOCKER_FRESH),true)
	docker compose build --no-cache --pull --build-arg RABBITMQ_DOCKER_TAG=$(RABBITMQ_DOCKER_TAG)
	docker compose up --pull always $(COMPOSE_UP_ARGS)
else
	docker compose build --build-arg RABBITMQ_DOCKER_TAG=$(RABBITMQ_DOCKER_TAG)
	docker compose up $(COMPOSE_UP_ARGS)
endif

perms:
	sudo chown -R "$$(id -u):$$(id -g)" data log

rmq-perms:
	sudo chown -R '999:999' data log

enable-ff:
	docker compose exec -T rmq0 rabbitmqctl enable_feature_flag all

upgrade-from:
	$(MAKE) up RABBITMQ_DOCKER_TAG=$(RABBITMQ_UPGRADE_FROM_DOCKER_TAG) COMPOSE_UP_ARGS=--detach

upgrade-image:
	docker compose build --pull --build-arg RABBITMQ_DOCKER_TAG=$(RABBITMQ_UPGRADE_DOCKER_TAG)

upgrade: upgrade-image
	RABBITMQ_EXPECTED_VERSION='$(RABBITMQ_EXPECTED_VERSION)' $(CURDIR)/upgrade.sh
