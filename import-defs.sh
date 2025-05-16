#!/bin/sh

set -e

for SVC in rmq-ds rmq-us
do
    # NB: https://github.com/docker/compose/issues/1262
    container_id="$(docker compose ps -q "$SVC")"
    docker exec "$container_id" /opt/rabbitmq/sbin/rabbitmqctl await_startup
    docker exec "$container_id" /opt/rabbitmq/sbin/rabbitmqctl import_definitions /var/lib/rabbitmq/definitions.json
done
