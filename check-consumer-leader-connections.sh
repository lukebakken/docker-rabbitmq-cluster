#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

declare -r green='\033[0;32m'
declare -r yellow='\033[1;33m'
declare -r red='\033[0;31m'
declare -r blue='\033[0;34m'
declare -r nc='\033[0m'

declare debug_mode=false

log_info() {
    echo -e "${blue}[$(date '+%H:%M:%S')]${nc} $1"
}

log_success() {
    echo -e "${green}[$(date '+%H:%M:%S')]${nc} $1"
}

log_warning() {
    echo -e "${yellow}[$(date '+%H:%M:%S')]${nc} $1"
}

log_error() {
    echo -e "${red}[$(date '+%H:%M:%S')]${nc} $1"
}

log_debug() {
    if [[ "$debug_mode" == "true" ]]
    then
        echo "  DEBUG: $1" >&2
    fi
}

main() {
    if [[ "${1:-}" == "--debug" ]]
    then
        debug_mode=true
        log_info "Debug mode enabled"
    fi

    local -i iteration=0
    local -i consumers_on_leader_count=0

    log_info "Starting consumer-leader connection check (Press CTRL-C to stop)"
    echo ""

    local -ri wait_time_secs=30
    while true
    do
        (( ++iteration ))

        log_info "=== Iteration $iteration ==="

        log_info "Checking stream leaders..."
        declare -A stream_leaders
        local -i stream_count=0
        while IFS=: read -r stream leader
        do
            stream_leaders["$stream"]="$leader"
            echo "  $stream -> $leader"
            (( ++stream_count ))
        done < <(docker compose exec rmq0 rabbitmqctl list_queues name type leader --formatter=json 2>/dev/null | \
            jq -r '.[] | select(.type == "stream") | "\(.name):\(.leader)"')

        log_debug "Found $stream_count streams"

        log_info "Building PID to node mapping..."
        declare -A pid_to_node
        while IFS=: read -r pid node; do
            pid_to_node["$pid"]="$node"
            log_debug "PID: $pid -> Node: $node"
        done < <(docker compose exec rmq0 rabbitmqctl list_stream_connections pid node --formatter=json 2>/dev/null | \
            jq -r '.[] | "\(.pid):\(.node)"')

        log_info "Checking for consumers on leader nodes..."
        local found_consumer_on_leader=false
        local -i checks_performed=0

        log_debug "Iterating over ${#stream_leaders[@]} stream(s)"
        for stream in "${!stream_leaders[@]}"
        do
            (( ++checks_performed ))
            local leader="${stream_leaders[$stream]}"

            log_debug "Check $checks_performed - Stream: '$stream', Leader: '$leader'"

            while IFS=: read -r pid; do
                local node="${pid_to_node[$pid]}"
                log_debug "  Consumer PID: $pid -> Node: $node"
                
                if [[ "$node" == "$leader" ]]; then
                    log_warning "Consumer on leader for stream '$stream' (PID: $pid, Node: $leader)"
                    found_consumer_on_leader=true
                    (( ++consumers_on_leader_count ))
                fi
            done < <(docker compose exec rmq0 rabbitmqctl list_stream_consumers stream connection_pid --formatter=json 2>/dev/null | \
                jq -r --arg stream "$stream" '.[] | select(.stream == $stream) | .connection_pid')
        done

        log_debug "Performed $checks_performed checks, found_consumer_on_leader=$found_consumer_on_leader"

        if [[ "$found_consumer_on_leader" == "false" ]]
        then
            log_success "No consumers on leader nodes"
        fi

        echo ""
        log_info "Total consumers found on leaders so far: $consumers_on_leader_count"

        echo ""
        echo "---"
        echo ""

        log_info "Restarting client applications..."
        docker compose restart java-stream-client-app dotnet-stream-client-app >/dev/null 2>&1

        log_info "Waiting $wait_time_secs seconds for connections to establish and for some activity..."
        sleep "$wait_time_secs"

        echo ""
        echo "---"
        echo ""
    done
}

main "$@"
