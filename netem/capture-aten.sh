#!/usr/bin/env bash

# Sample each node's view of every peer's failure probability and log it,
# building an observer x peer matrix over time.
#
# aten_sink:get_failure_probabilities/0 returns a map of peer node ->
# probability (0.0 healthy .. 1.0 considered down) from the heartbeats the
# node has received. Sampling it on all nodes shows whether a single faulty
# node stands out to its healthy peers.

set -o errexit
set -o nounset
set -o pipefail

readonly default_secs=600
readonly default_interval=1
readonly out_dir="out"
declare -ra nodes=(rmq0 rmq1 rmq2)
readonly eval_expr='aten_sink:get_failure_probabilities().'

show_usage() {
    cat << EOF
Usage: $0 [duration-seconds] [interval-seconds]

Every interval, runs "rabbitmqctl eval '$eval_expr'" on each node and
appends a timestamped line per observer to $out_dir/aten-capture.log.

Arguments:
  duration-seconds  total capture time (default: $default_secs)
  interval-seconds  seconds between samples (default: $default_interval)

Line format:
  <iso-8601> observer=<node> <erlang-map>
EOF
}

sample_node() {
    local -r node="$1"
    local raw

    # A sample can fail exactly when it matters most: while the node is being
    # degraded, rabbitmqctl eval may error or time out. Record the failure and
    # keep capturing rather than letting errexit kill the run.
    if ! raw=$(docker compose exec -T "$node" \
        rabbitmqctl eval "$eval_expr" < /dev/null 2>&1 | tr '\n' ' ')
    then
        raw="[sample-failed] $raw"
    fi

    printf '%s observer=%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$node" "$raw"
}

main() {
    case "${1:-}" in
        --help|-h)
            show_usage
            exit 0
            ;;
    esac

    local -ri secs="${1:-$default_secs}"
    local -ri interval="${2:-$default_interval}"

    mkdir -p "$out_dir"
    local -r out_file="$out_dir/aten-capture.log"

    echo "Capturing aten probabilities from ${nodes[*]} for ${secs}s every ${interval}s" >&2
    echo "Writing to $out_file (Ctrl-C to stop early)" >&2

    local node
    local -i deadline=$(( SECONDS + secs ))
    while (( SECONDS < deadline ))
    do
        for node in "${nodes[@]}"
        do
            sample_node "$node" >> "$out_file"
        done
        sleep "$interval"
    done

    echo "Capture complete: $out_file" >&2
}

main "$@"
