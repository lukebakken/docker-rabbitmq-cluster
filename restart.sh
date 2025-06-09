#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# shellcheck disable=SC2155,SC2034
readonly dir="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"

echo "[INFO] restarting cluster!"

for SVC in rmq0 rmq1 rmq2
do
    docker compose exec "$SVC" rabbitmq-upgrade drain
    docker compose exec "$SVC" rabbitmqctl stop_app
    docker compose stop "$SVC"
    sleep 5
    docker compose up --detach "$SVC"
done
