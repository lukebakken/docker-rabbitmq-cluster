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

# gen_server2 does not implement system_get_state/1, so sys:get_state/1 returns its whole
# #gs2_state{} record, whose element 4 is the module state. `sender_queues` is element 8 of the
# #state{} record in rabbit_mirror_queue_slave in 3.13.7. The matches fail loudly if either
# shape changes.
declare -r erl_expr='
Me = node(),
Mirrors = [P || Q <- rabbit_amqqueue:list(<<"/">>),
                P <- case amqqueue:get_slave_pids(Q) of L when is_list(L) -> L; _ -> [] end,
                node(P) =:= Me],
SenderQueues = fun(P) ->
                   GS = sys:get_state(P),
                   gs2_state = element(1, GS),
                   rabbit_mirror_queue_slave = element(5, GS),
                   St = element(4, GS),
                   state = element(1, St),
                   element(8, St)
               end,
Held = lists:sum([lists:sum([queue:len(MQ) || {MQ, _, _} <- maps:values(SenderQueues(P))])
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
