#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

echo "=== Stream Leaders ==="

declare -A stream_leaders
while IFS=: read -r stream leader
do
    stream_leaders["$stream"]="$leader"
    echo "  $stream -> $leader"
done < <(docker compose exec rmq0 rabbitmqctl list_queues name type leader --formatter=json | \
    jq -r '.[] | select(.type == "stream") | "\(.name):\(.leader)"')

echo
echo "=== Building PID to Node mapping ==="

declare -A pid_to_node
connection_data=$(docker compose exec rmq0 rabbitmqctl list_stream_connections pid node --formatter=json | \
    jq -r '.[] | "\(.pid):\(.node)"')

if [[ -n "$connection_data" ]]
then
    while IFS=: read -r pid node
    do
        pid_to_node["$pid"]="$node"
    done <<< "$connection_data"
    echo "Mapped ${#pid_to_node[@]} connections"
else
    echo "Mapped 0 connections"
    echo "No consumers found on leader nodes"
    exit 0
fi

echo
echo "=== Checking for Consumers on Leader Nodes ==="
declare -i found=0

for stream in "${!stream_leaders[@]}"
do
    leader="${stream_leaders[$stream]}"
    
    while IFS=: read -r pid
    do
        if [[ -n "${pid_to_node[$pid]:-}" ]]
        then
            node="${pid_to_node[$pid]}"
            if [[ "$node" == "$leader" ]]
            then
                echo "FOUND: Consumer for stream '$stream' (PID: $pid) on leader node $leader"
                ((found++))
            fi
        fi
    done < <(docker compose exec rmq0 rabbitmqctl list_stream_consumers stream connection_pid --formatter=json | \
        jq -r --arg stream "$stream" '.[] | select(.stream == $stream) | .connection_pid')
done

if (( found == 0 ))
then
    echo "No consumers found on leader nodes"
fi

echo
echo "Total consumers on leaders: $found"
