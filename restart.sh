#!/usr/bin/env bash

set -o errexit
set -o nounset

echo "[INFO] performing a cluster rolling restart..."

set +o errexit
for idx in 0 1 2
do
    svc="rmq$idx"
    echo "[INFO] draining and restaring svc: $svc"
    docker compose exec --no-tty "$svc" /opt/rabbitmq/sbin/rabbitmq-upgrade drain
    docker compose stop "$svc"
    if (( idx < 2 ))
    then
        sleep 10
    fi
    docker compose up --remove-orphans --detach --no-deps "$svc"
done

echo "[INFO] DONE"
