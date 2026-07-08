#!/usr/bin/env bash

# Shared helpers for the #11495 federation-roster-stranding reproduction,
# sourced by the Makefile's load / status / restart-loop targets.
#
# Configuration comes from the environment (the Makefile exports it); each
# value has a fallback so the script also runs standalone for debugging.

set -o errexit
set -o nounset
set -o pipefail

readonly host="${HOST:-127.0.0.1}"
readonly rmq_user="${RMQ_USER:-guest}"
readonly rmq_pass="${RMQ_PASS:-guest}"
readonly definitions="${DEFINITIONS:-definitions.json}"
readonly restart_mode="${RESTART_MODE:-drain}"
declare -ri restart_iterations="${RESTART_ITERATIONS:-25}"
declare -ri live_attempts="${LIVE_ATTEMPTS:-60}"
declare -ri health_attempts="${HEALTH_ATTEMPTS:-120}"
declare -ri link_attempts="${LINK_ATTEMPTS:-40}"
declare -ri rebalance_attempts="${REBALANCE_ATTEMPTS:-60}"

read -r -a nodes <<< "${NODES:-rmq0 rmq1 rmq2}"
read -r -a mgmt_ports <<< "${MGMT_PORTS:-8872 8873 8874}"

# Echo the first management port whose node answers /api/overview, so status
# and link checks survive a node being mid-restart. Empty output => none up.
live_port() {
    local -i port
    for port in "${mgmt_ports[@]}"
    do
        if curl -s -o /dev/null -u "$rmq_user:$rmq_pass" "http://$host:$port/api/overview"
        then
            printf '%s' "$port"
            return 0
        fi
    done
    return 1
}

# Block until at least one node answers the management API, or fail after the
# configured number of 2s attempts. `make up` returns as soon as containers
# start (detached), well before RabbitMQ is accepting API calls, so any
# operation that needs a live node must wait rather than fail on the first miss.
wait_for_live() {
    local -i attempt=0
    while (( attempt < live_attempts ))
    do
        if live_port >/dev/null
        then
            return 0
        fi
        (( ++attempt ))
        sleep 2
    done
    echo "wait_for_live: no node answered the management API after $(( live_attempts * 2 ))s" >&2
    return 1
}

# Count running nodes as seen from any live node.
count_running_nodes() {
    local -i port
    port=$(live_port) || { printf '0'; return 0; }
    curl -s -u "$rmq_user:$rmq_pass" "http://$host:$port/api/nodes" \
        | jq '[.[] | select(.running == true)] | length'
}

# Count federation links currently in the "running" state.
count_links() {
    local -i port
    port=$(live_port) || { printf '0'; return 0; }
    curl -s -u "$rmq_user:$rmq_pass" "http://$host:$port/api/federation-links" \
        | jq '[.[] | select(.status == "running")] | length'
}

# Count federation-internal queues (auto-created, one per running link, named
# "federation: <exch> -> <node>:<hub>:<exch>"). In a healthy cluster this equals
# the running-link count 1:1. A drain/revive cycle can leave orphaned internal
# queues behind (consumerless, naming the node the link ran on at creation),
# so a count exceeding the running-link count is the #11495 roster leak -- and
# it is invisible to count_links, which stays at baseline throughout.
count_internal_queues() {
    local -i port
    port=$(live_port) || { printf '0'; return 0; }
    curl -s -u "$rmq_user:$rmq_pass" "http://$host:$port/api/queues?columns=name" \
        | jq '[.[] | select(.name | startswith("federation:"))] | length'
}

# True when every node reports no resource alarms.
no_alarms() {
    local -i port
    port=$(live_port) || return 1
    local status
    status=$(curl -s -u "$rmq_user:$rmq_pass" \
        "http://$host:$port/api/health/checks/alarms" | jq -r '.status // "unknown"')
    [[ "$status" == "ok" ]]
}

# Block until all nodes are running and free of alarms, or fail after the
# configured number of 2s attempts.
wait_healthy() {
    local -i attempt=0
    local -i want="${#nodes[@]}"
    while (( attempt < health_attempts ))
    do
        if (( $(count_running_nodes) == want )) && no_alarms
        then
            return 0
        fi
        (( ++attempt ))
        sleep 2
    done
    echo "wait_healthy: cluster not healthy after $(( health_attempts * 2 ))s" >&2
    return 1
}

# Block until the running-link count reaches the given baseline. Federation
# links reconnect after a ~5s delay following a node restart, so a transient
# dip is expected; only a persistent shortfall is a stranding.
wait_links() {
    local -ri baseline="$1"
    local -i attempt=0
    while (( attempt < link_attempts ))
    do
        if (( $(count_links) >= baseline ))
        then
            return 0
        fi
        (( ++attempt ))
        sleep 3
    done
    return 1
}

# Largest number of queue leaders hosted on any single node. Definitions import
# lands every leader on the importing node; a balanced 3-node cluster of N
# queues has a max share near N/3.
max_leader_share() {
    local -i port
    port=$(live_port) || { printf '0'; return 0; }
    curl -s -u "$rmq_user:$rmq_pass" "http://$host:$port/api/queues?columns=node" \
        | jq 'group_by(.node) | map(length) | max // 0'
}

# Trigger an asynchronous leader rebalance and block until the distribution is
# even (max share within ceil(total/nodes) + a slack margin) or the attempt
# budget is exhausted. The rebalance endpoint returns 204 immediately and gives
# no completion signal, so we poll max_leader_share to detect convergence.
rebalance() {
    wait_for_live || return 1
    local -i port
    port=$(live_port) || { echo "rebalance: no live node" >&2; return 1; }
    local -i code
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "$rmq_user:$rmq_pass" \
        -X POST "http://$host:$port/api/rebalance/queues/")
    if (( code != 204 ))
    then
        echo "rebalance: POST /api/rebalance/queues/ returned HTTP $code" >&2
        return 1
    fi
    local -i total nodecount target attempt=0
    total=$(curl -s -u "$rmq_user:$rmq_pass" "http://$host:$port/api/queues?columns=name" | jq length)
    nodecount="${#nodes[@]}"
    target=$(( (total + nodecount - 1) / nodecount + total / 20 ))
    while (( attempt < rebalance_attempts ))
    do
        if (( $(max_leader_share) <= target ))
        then
            return 0
        fi
        (( ++attempt ))
        sleep 5
    done
    echo "rebalance: leaders still uneven after $(( rebalance_attempts * 5 ))s (max share $(max_leader_share), target <= $target)" >&2
    return 1
}

# Import the scrubbed topology, then rebalance leaders off the import node.
# Uses the management HTTP API directly because rabbitmqadmin v2.32 'definitions
# import' fails on this payload; a plain POST to /api/definitions returns 204.
# Host must be 127.0.0.1 (containers bind IPv4 only; 'localhost' resolves to ::1
# here and is unreachable).
do_load() {
    wait_for_live || return 1
    local -i port
    port=$(live_port) || { echo "do_load: no live node" >&2; return 1; }
    local -i code
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "$rmq_user:$rmq_pass" \
        -H 'content-type: application/json' \
        -X POST --data-binary "@$definitions" \
        "http://$host:$port/api/definitions")
    if (( code < 200 || code >= 300 ))
    then
        echo "do_load: POST /api/definitions returned HTTP $code" >&2
        return 1
    fi
    echo "imported $definitions"
    echo "rebalancing leaders off the import node..."
    rebalance
    print_status
}

# Report topology + federation roster counts (no entity names).
print_status() {
    wait_for_live || return 1
    local -i port
    port=$(live_port) || { echo "print_status: no live node" >&2; return 1; }
    local -r base="http://$host:$port/api"
    printf 'vhosts        : %s\n' "$(curl -s -u "$rmq_user:$rmq_pass" "$base/vhosts" | jq length)"
    local queues
    queues=$(curl -s -u "$rmq_user:$rmq_pass" "$base/queues")
    printf 'queues        : %s\n' "$(jq length <<< "$queues")"
    printf '  quorum      : %s\n' "$(jq '[.[] | select(.arguments["x-queue-type"] == "quorum")] | length' <<< "$queues")"
    printf '  classic     : %s\n' "$(jq '[.[] | select(.arguments["x-queue-type"] != "quorum")] | length' <<< "$queues")"
    printf 'policies      : %s\n' "$(curl -s -u "$rmq_user:$rmq_pass" "$base/policies" | jq length)"
    printf 'fed upstreams : %s\n' "$(curl -s -u "$rmq_user:$rmq_pass" "$base/parameters/federation-upstream" | jq length)"
    printf 'fed links     : %s running\n' "$(count_links)"
}

# Rolling-restart the cluster restart_iterations times, one node per step,
# waiting for full health AND for the federation roster to return to its
# captured baseline between passes. Two independent failure signals are checked
# each pass:
#   1. running-link count drops below baseline (links fail to re-establish) --
#      hard failure, returns non-zero.
#   2. internal-queue count exceeds the running-link count -- the #11495 roster
#      leak: orphaned federation-internal queues left behind by drain/revive.
#      This is INVISIBLE to signal 1 (the running-link count returns to baseline
#      while orphans accumulate), so it is reported per pass and tracked, but
#      does NOT abort -- run multiple passes to watch it compound.
restart_loop() {
    wait_for_live || return 1
    local -i baseline baseline_internal
    baseline=$(count_links)
    baseline_internal=$(count_internal_queues)
    echo "baseline: $baseline running links, $baseline_internal internal queues"
    if (( baseline == 0 ))
    then
        echo "no links running -- run 'make load' first" >&2
        return 1
    fi
    local -i iter links internal orphans
    local node
    for (( iter = 1; iter <= restart_iterations; iter++ ))
    do
        echo "=== rolling pass $iter/$restart_iterations (mode=$restart_mode) ==="
        for node in "${nodes[@]}"
        do
            restart_node "$node"
            wait_healthy
        done
        if ! wait_links "$baseline"
        then
            echo "!!! #11495 link stranding at pass $iter: $(count_links) running < $baseline baseline" >&2
            return 1
        fi
        links=$(count_links)
        internal=$(count_internal_queues)
        orphans=$(( internal - links ))
        if (( orphans > 0 ))
        then
            echo "pass $iter: $links links running, but $internal internal queues -> $orphans ORPHANED (roster leak)"
        else
            echo "pass $iter: $links links running, $internal internal queues (clean 1:1)"
        fi
    done
    echo "done after $restart_iterations passes"
}

# Restart one node. Modes:
#   drain (default) - rabbitmq-upgrade drain (suspend listeners + transfer quorum
#                     and classic-mirrored leadership off the node) -> stop the
#                     BEAM -> start it -> rabbitmq-upgrade revive (resume
#                     listeners, host primary replicas again). This drives the
#                     leadership-transfer / mirrored_supervisor teardown path
#                     that #11495 implicates.
#   node            - abrupt container restart (SIGTERM), no drain. Models an
#                     ungraceful failure/replacement; contrast case.
#   app             - restart only the RabbitMQ app inside the running BEAM.
restart_node() {
    local -r node="$1"
    case "$restart_mode" in
        drain)
            docker compose exec -T "$node" rabbitmq-upgrade drain >&2
            docker compose stop "$node" >&2
            docker compose start "$node" >&2
            wait_healthy
            docker compose exec -T "$node" rabbitmq-upgrade revive >&2
            ;;
        node)
            docker compose restart "$node" >&2
            ;;
        app)
            docker compose exec -T "$node" rabbitmqctl --quiet stop_app >&2
            docker compose exec -T "$node" rabbitmqctl --quiet start_app >&2
            ;;
        *)
            echo "restart_node: unknown RESTART_MODE '$restart_mode' (want drain|node|app)" >&2
            return 1
            ;;
    esac
}
