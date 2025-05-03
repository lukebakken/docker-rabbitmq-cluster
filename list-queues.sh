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
    local tmp="$(mktemp -d)"
    readonly tmp

    while :
    do
        info "listing queues on port '$port'..."
        rabbitmqadmin --port "$port" list queues --non-interactive > "$tmp/queues-$port.txt"
        sleep 30
    done
}

list_queues 15672 &
sleep "$(($RANDOM % 10))"

list_queues 15673 &
sleep "$(($RANDOM % 10))"

list_queues 15674 &

wait
