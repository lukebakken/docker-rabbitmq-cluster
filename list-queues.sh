#!/usr/bin/env bash

# script_dir="$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# readonly script_dir

function now
{
    date +%Y%m%dT-%H%M%S%z
}

function info
{
    printf '%s [INFO] %s\n' "$(now)" "$@"
}

function list_queues
{
    local -ri port=$1
    tmp="$(mktemp -d)"
    local -r tmp

    while :
    do
        info "listing queues on port '$port'..."
        curl -sku 'guest:guest' "localhost:$port/api/queues?columns=name,type,state,vhost,auto_delete,consumers,exclusive,leader,members,message_bytes,messages,messages_persistent,messages_ready,messages_unacknowledged,node,online,slave_nodes,sync_messages,synchronised_slave_nodes" > "$tmp/queues-$port.txt"
        sleep 30
    done
}

list_queues 15672 &
sleep "$((RANDOM % 10))"

list_queues 15673 &
sleep "$((RANDOM % 10))"

list_queues 15674 &

wait
