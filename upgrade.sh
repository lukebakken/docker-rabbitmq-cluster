#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# shellcheck disable=SC2155,SC2034
readonly dir="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"

echo "[INFO] upgrading cluster!"

for SVC in rmq0 rmq1 rmq2
do
    # NB: https://github.com/docker/compose/issues/1262
    container_id="$(docker compose ps -q "$SVC")"
    set +o errexit
    docker exec "$container_id" /opt/rabbitmq/sbin/rabbitmq-upgrade drain
    set -o errexit
    docker compose stop "$SVC"
    sleep 5
    docker compose up --detach "$SVC"
done

docker compose exec rmq0 rabbitmqctl enable_feature_flag all
