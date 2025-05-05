#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

script_dir="$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir

function now
{
    date +%Y%m%dT-%H%M%S%z
}

function info
{
    printf '%s [INFO] %s\n' "$(now)" "$@"
}

function warning
{
    printf '%s [WARNING] %s\n' "$(now)" "$@" 1>&2
}

function create_queues
{
    local -i start=$1
    local -i end=$2
    local -i port=15672
    info "START creating queues $start through $end"
    for ((i = start; i < end; i++))
    do
        port="$((15672 + (i % 3)))"
        if ! "$script_dir/bin/rabbitmqadmin" --port "$port" declare queue --type quorum --name "qq-$i"
        then
            warning "error creating queue qq-$i, \$?: $?"
        fi
    done
    info "DONE creating queues $start through $end"
}

set +o errexit
create_queues 0 1999 &
create_queues 2000 3999 &
create_queues 4000 5999 &
create_queues 6000 7999 &
create_queues 8000 9999 &
create_queues 10000 11999 &
create_queues 12000 13999 &
create_queues 14000 15999 &
create_queues 16000 17999 &
create_queues 18000 19999 &


wait
