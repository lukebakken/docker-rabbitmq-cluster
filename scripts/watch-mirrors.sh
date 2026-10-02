#!/usr/bin/env bash

# Report, per node, the state that rabbitmq-server issue #9905 leaks: messages held in the
# `sender_queues` of local classic-mirrored-queue mirror processes, and the binary memory those
# processes reference. Message bodies are off-heap binaries, so `erlang:process_info(P, memory)`
# alone does not show the growth.
#
# Usage: scripts/watch-mirrors.sh [interval-seconds]

set -o errexit
set -o nounset
set -o pipefail

declare -ri interval="${1:-10}"
declare -ra nodes=(rmq0 rmq1 rmq2)

# `sender_queues` is element 8 of rabbit_mirror_queue_slave's #state{} record in 3.13.7.
declare -r erl_expr='
Me = node(),
Mirrors = [P || Q <- rabbit_amqqueue:list(<<"/">>),
                P <- case amqqueue:get_slave_pids(Q) of L when is_list(L) -> L; _ -> [] end,
                node(P) =:= Me],
Held = lists:sum([lists:sum([queue:len(MQ) || {MQ, _, _} <- maps:values(element(8, sys:get_state(P)))])
                  || P <- Mirrors]),
Bin = lists:sum([Sz || P <- Mirrors, {binary, B} <- [erlang:process_info(P, binary)], {_, Sz, _} <- B]),
io:format("~s total_mb=~b binary_mb=~b mirrors=~b held_msgs=~b mirror_binary_mb=~b~n",
          [Me, erlang:memory(total) div 1048576, erlang:memory(binary) div 1048576,
           length(Mirrors), Held, Bin div 1048576]).'

while true
do
    echo "--- $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    for node in "${nodes[@]}"
    do
        if output="$(docker compose exec -T "$node" rabbitmqctl eval "$erl_expr" < /dev/null 2>&1)"
        then
            echo "${output%$'\n'ok}"
        else
            echo "$node: eval failed: $output" >&2
        fi
    done
    sleep "$interval"
done
