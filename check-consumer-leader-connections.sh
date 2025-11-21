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

check_consumer_on_leader() {
    local -r stream="$1"
    local -r leader="$2"
    local -r consumer_pattern="$3"

    log_debug "Checking $consumer_pattern on $leader"

    local -r jq_query=".[] | select(.client_properties[] | select(.[0] == \"connection_name\" and (.[2] | contains(\"$consumer_pattern\")))) | select(.node == \"$leader\") | \"\(.client_properties[] | select(.[0] == \"connection_name\") | .[2]):\(.node)\""
    log_debug "JQ query: $jq_query"

    local consumer_on_leader
    consumer_on_leader=$(docker compose exec rmq0 rabbitmqctl list_stream_connections client_properties node --formatter=json 2>/dev/null | \
        jq -r "$jq_query" || true)
    local -r consumer_on_leader

    log_debug "Result: '$consumer_on_leader'"
    log_debug "Result length: ${#consumer_on_leader}"

    if [[ -n "$consumer_on_leader" ]]
    then
        log_warning "Consumer on leader for $stream (leader: $leader)"
        echo "  $consumer_on_leader"
        return 0
    fi

    return 1
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

        log_info "Checking for consumers on leader nodes..."
        local found_consumer_on_leader=false
        local -i checks_performed=0

        log_debug "Iterating over ${#stream_leaders[@]} stream(s)"
        for stream in "${!stream_leaders[@]}"
        do
            (( ++checks_performed ))
            local leader="${stream_leaders[$stream]}"
            local consumer_pattern=""

            log_debug "Check $checks_performed - Stream: '$stream', Leader: '$leader'"

            if [[ "$stream" == "java-stream-client-app" ]]
            then
                consumer_pattern="rabbitmq-stream-consumer"
            else
                consumer_pattern="dotnet-stream-consumer"
            fi

            log_debug "Using pattern: '$consumer_pattern'"

            if check_consumer_on_leader "$stream" "$leader" "$consumer_pattern"
            then
                log_debug "check_consumer_on_leader returned TRUE"
                found_consumer_on_leader=true
                (( ++consumers_on_leader_count ))
            else
                log_debug "check_consumer_on_leader returned FALSE"
            fi
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
