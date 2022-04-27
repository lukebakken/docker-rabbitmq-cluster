#!/bin/sh

set -e

for SVC in rmq0-ds rmq0-us
do
    docker compose run $SVC rabbitmqctl await_startup
    docker compose run $SVC rabbitmqctl import_definitions /var/lib/rabbitmq/definitions.json
done
