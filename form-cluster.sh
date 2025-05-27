#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

for svc in rmq1 rmq2
do
    docker compose exec "$svc" rabbitmqctl join_cluster rabbit@rmq0
done
