#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

docker compose exec rmq0 rabbitmqctl update_vhost_metadata / --default-queue-type classic

docker compose exec rmq0 rabbitmqctl list_vhosts name default_queue_type

./rabbitmqadmin declare queue name=should_be_classic

./rabbitmqadmin declare queue name=should_be_quorum arguments='{"x-queue-type":"quorum"}'

docker compose exec rmq0 rabbitmqctl list_queues name type
