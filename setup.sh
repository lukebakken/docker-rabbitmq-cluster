#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

function create_queues
{
    local -i start=$1
    local -i end=$2
    local -i port=15672
    for ((i = start; i < end; i++))
    do
        port="$((15672 + (i % 3)))"
        rabbitmqadmin --port "$port" declare queue --type quorum --name "qq-$i"
    done
}

create_queues 0 1999 &
create_queues 2000 3999 &
create_queues 4000 5999 &
create_queues 6000 7999 &
create_queues 8000 9999 &

wait
