#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# Every docker compose call below is bare, so it would otherwise resolve the
# project from the caller's working directory and roll somebody else's cluster.
cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")"

readonly services=(rmq0 rmq1 rmq2)

# Set by the Makefile. Only used to tell an upgrade apart from a restart, so an
# empty value weakens the final check rather than breaking the roll.
readonly expected_version="${RABBITMQ_EXPECTED_VERSION:-}"

assert_all_feature_flags_enabled() {
    local svc="$1" flags report total disabled flag

    # tr strips the carriage returns a TTY-allocating exec would add, which the
    # state comparison below is otherwise sensitive to.
    if ! flags="$(docker compose exec -T "$svc" rabbitmqctl --quiet list_feature_flags name state --formatter=csv | tr -d '\r')"
    then
        echo "[ERROR] cannot read feature flags from $svc" >&2
        return 1
    fi

    # One pass emits the data row count on the first line and any disabled flag
    # names after it, so the count and the names cannot disagree about which
    # rows are data. The header is skipped by its contents rather than by line
    # number, which a stray line on stdout would shift. awk also exits 0 on no
    # matches, where grep -c returns 1 and under errexit would kill the script
    # before the count could be reported.
    report="$(awk -F, '
        /^"/ && $1 != "\"name\"" {
            total++
            if ($2 != "\"enabled\"") {
                gsub(/"/, "", $1)
                disabled = disabled "\n" $1
            }
        }
        END { print total + 0 disabled }' <<< "$flags")"

    total="$(head -n 1 <<< "$report")"
    if [[ "$total" -lt 1 ]]
    then
        echo "[ERROR] $svc reported no feature flags" >&2
        return 1
    fi

    disabled="$(tail -n +2 <<< "$report")"
    if [[ -n "$disabled" ]]
    then
        echo "[ERROR] these feature flags are not enabled, run 'make enable-ff' first:" >&2
        while IFS= read -r flag
        do
            echo "  $flag" >&2
        done <<< "$disabled"
        return 1
    fi

    echo "[INFO] all $total feature flags are enabled"
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

node_version() {
    local svc="$1" version

    # Assigned rather than interpolated into an echo, so that a failure here
    # aborts instead of printing an empty version and draining the next node.
    version="$(docker compose exec -T "$svc" rabbitmqctl --quiet version | tr -d '\r')"
    if [[ -z "$version" ]]
    then
        echo "[ERROR] $svc reported no version" >&2
        return 1
    fi

    echo "$version"
}

assert_every_node_upgraded() {
    local svc version first=''

    for svc in "${services[@]}"
    do
        version="$(node_version "$svc")"
        echo "[INFO] $svc: running $version"

        if [[ -n "$first" && "$version" != "$first" ]]
        then
            echo "[ERROR] cluster is running mixed versions: $first and $version" >&2
            return 1
        fi
        first="$version"

        if [[ -n "$expected_version" && "$version" != "$expected_version" ]]
        then
            echo "[ERROR] $svc is running $version, expected $expected_version" >&2
            return 1
        fi
    done

    if [[ -z "$expected_version" ]]
    then
        echo "[WARN] RABBITMQ_EXPECTED_VERSION is unset, so a restart that upgraded nothing would still pass" >&2
    fi
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
done

# A rolling upgrade leaves every queue and stream leader on the nodes that were
# drained first, so the cluster is lopsided until this runs.
echo "[INFO] rebalancing queue and stream leaders"
docker compose exec -T "${services[0]}" rabbitmq-upgrade post_upgrade

assert_every_node_upgraded
docker compose exec -T "${services[0]}" rabbitmqctl cluster_status

# Last, so that it cannot claim success for a cluster that failed a check above.
echo "[INFO] upgrade complete"
