#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# shellcheck disable=SC2155,SC2034
readonly dir="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"

readonly services=(rmq0 rmq1 rmq2)

assert_all_feature_flags_enabled() {
    local svc="$1" disabled
    disabled="$(docker compose exec -T "$svc" rabbitmqctl list_feature_flags name state --formatter=csv 2>/dev/null |
        awk -F, 'NR>1 && $2!="\"enabled\"" {print $1}')"
    if [[ -n "$disabled" ]]
    then
        echo "[ERROR] these feature flags are not enabled, run 'make enable-ff' first:" >&2
        echo "$disabled" >&2
        return 1
    fi
    echo "[INFO] all feature flags are enabled"
}

await_startup() {
    local svc="$1" i
    for ((i = 0; i < 150; i++))
    do
        if docker compose exec -T "$svc" rabbitmqctl await_startup > /dev/null 2>&1
        then
            return 0
        fi
        sleep 2
    done
    echo "[ERROR] $svc did not finish starting" >&2
    return 1
}

echo "[INFO] upgrading cluster!"

assert_all_feature_flags_enabled "${services[0]}"

for SVC in "${services[@]}"
do
    echo "[INFO] $SVC: waiting for every queue and stream to have quorum to spare"
    docker compose exec -T "$SVC" rabbitmq-upgrade await_online_quorum_plus_one

    echo "[INFO] $SVC: draining"
    docker compose exec -T "$SVC" rabbitmq-upgrade drain

    echo "[INFO] $SVC: restarting onto the new image"
    docker compose stop "$SVC"
    docker compose up --detach "$SVC"

    await_startup "$SVC"
    echo "[INFO] $SVC: now running $(docker compose exec -T "$SVC" rabbitmqctl version | tr -d '\r')"
done

echo "[INFO] upgrade complete"
docker compose exec -T "${services[0]}" rabbitmqctl cluster_status
