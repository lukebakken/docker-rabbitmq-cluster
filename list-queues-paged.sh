#!/usr/bin/env bash

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

    while :
    do
        for ((page=1; page <= 40; page++))
        do
            info "listing queues on port '$port', page '$page'..."
            curl -sku 'guest:guest' "localhost:$port/api/queues?page=$page&page_size=500&columns=name,type,state,vhost,auto_delete,consumers,exclusive,leader,members,message_bytes,messages,messages_persistent,messages_ready,messages_unacknowledged,node,online,slave_nodes,sync_messages,synchronised_slave_nodes" > /dev/null
        done
        sleep 30
    done
}

list_queues 15672 &
sleep "$((RANDOM % 10))"

list_queues 15673 &
sleep "$((RANDOM % 10))"

list_queues 15674 &

wait
