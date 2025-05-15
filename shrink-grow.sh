#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

declare -r ha_operator_policy_name="${1:-ha-all}"
declare -r queue="${2:-ha-queue-0-0}"

declare -a nodes
readarray -t nodes < <(curl -4su 'guest:guest' 'localhost:15672/api/nodes' | jq -r '.[] | .name')
declare -r nodes
echo "nodes: ${nodes[*]}"

queue_leader="$(curl -4su 'guest:guest' "localhost:15672/api/queues/%2F/$queue" | jq -r '.node')"
declare -r queue_leader

echo "queue leader: $queue_leader"

new_queue_leader=''
for node in "${nodes[@]}"
do
    if [[ $node != "$queue_leader" ]]
    then
        new_queue_leader="$node"
        break
    fi
done

echo "new queue leader: $new_queue_leader"

curl -4su 'guest:guest' -H 'Content-Type: application/json' -XPUT "localhost:15672/api/operator-policies/%2F/$queue-shrink" \
     -d "{\"pattern\":\"^$queue\$\",\"priority\":999,\"apply-to\":\"queues\",\"definition\":{\"ha-mode\":\"nodes\",\"ha-params\":[\"$new_queue_leader\"],\"ha-sync-mode\":\"automatic\"}}"

echo "check for new leader now, any key to continue..."
read -r

# Delete shrink policy
curl -4su 'guest:guest' -H 'Content-Type: application/json' -XDELETE "localhost:15672/api/operator-policies/%2F/$queue-shrink"
