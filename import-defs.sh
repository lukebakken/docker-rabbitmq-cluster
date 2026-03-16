#!/bin/sh

set -eux

docker compose exec rmq0 /opt/rabbitmq/sbin/rabbitmqctl await_startup
docker compose exec rmq0 /opt/rabbitmq/sbin/rabbitmqctl import_definitions /var/lib/rabbitmq/definitions.json
