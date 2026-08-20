#!/usr/bin/env bash

# Inject packet loss on one node in regular on/off intervals, modelling the
# incident's reported pattern of periodic drops rather than steady loss.
#
# Runs until interrupted (Ctrl-C); clears the qdisc on exit.

set -o errexit
set -o nounset
set -o pipefail

readonly default_iface="eth0"
readonly default_on=5
readonly default_off=10

show_usage() {
    cat << EOF
Usage: $0 <node> <loss-percent> [on-seconds] [off-seconds] [iface]

Repeatedly applies <loss-percent>% egress loss for <on-seconds>, then
clears it for <off-seconds>, until interrupted.

Arguments:
  node          compose service name (e.g. rmq0)
  loss-percent  integer 0-100
  on-seconds    seconds with loss applied (default: $default_on)
  off-seconds   seconds with clean networking (default: $default_off)
  iface         network interface (default: $default_iface)

Example:
  $0 rmq0 48 5 10
EOF
}

node=""
iface="$default_iface"

cleanup() {
    if [[ -n "$node" ]]
    then
        echo >&2
        echo "Interrupted: clearing qdisc on $node ($iface)" >&2
        docker compose exec -T "$node" \
            tc qdisc del dev "$iface" root < /dev/null 2>/dev/null || true
    fi
}

main() {
    case "${1:-}" in
        --help|-h)
            show_usage
            exit 0
            ;;
    esac

    if (( $# < 2 ))
    then
        show_usage
        exit 1
    fi

    node="$1"
    local -r loss="$2"
    local -ri on_secs="${3:-$default_on}"
    local -ri off_secs="${4:-$default_off}"
    iface="${5:-$default_iface}"

    if ! [[ "$loss" =~ ^[0-9]+$ ]] || (( loss > 100 ))
    then
        echo "Error: loss-percent must be an integer 0-100, got '$loss'" >&2
        exit 1
    fi

    trap cleanup EXIT INT TERM

    echo "Periodic loss on $node ($iface): ${loss}% for ${on_secs}s, clean for ${off_secs}s. Ctrl-C to stop." >&2
    while true
    do
        echo "[$(date '+%H:%M:%S')] loss ON (${loss}%)" >&2
        docker compose exec -T "$node" \
            tc qdisc replace dev "$iface" root netem loss "${loss}%" < /dev/null
        sleep "$on_secs"

        echo "[$(date '+%H:%M:%S')] loss OFF" >&2
        docker compose exec -T "$node" \
            tc qdisc del dev "$iface" root < /dev/null 2>/dev/null || true
        sleep "$off_secs"
    done
}

main "$@"
