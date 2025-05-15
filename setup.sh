#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

declare -ri i_end="${1:-3}"
declare -ri j_end="${2:-3}"

rabbitmqadmin declare operator_policy 'name=ha-all' 'pattern=^ha-queue' 'apply-to=queues' 'definition={"ha-mode":"all","ha-sync-mode":"automatic"}'

for prefix in ha-queue non-ha-queue
do
    for ((i = 0; i < i_end; i++))
    do
        for ((j = 0; j < j_end; j++))
        do
            port="$((8872 + j % 3))" # Note: docker exposed port
            rabbitmqadmin --port=$port declare queue "name=$prefix-$i-$j" durable=true queue_type=classic
        done
    done
done

for ((i = 0; i < i_end; i++))
do
    for ((j = 0; j < j_end; j++))
    do
        port="$((8872 + j % 3))"
        rabbitmqadmin --port=$port declare queue "name=qq-$i-$j" durable=true queue_type=quorum
    done
done
