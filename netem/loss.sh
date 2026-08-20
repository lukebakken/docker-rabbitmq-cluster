#!/usr/bin/env bash

# Inject egress packet loss on one node's interface using tc/netem.
#
# Egress-only is deliberate: dropping a node's OUTBOUND heartbeats makes
# both healthy peers see that node as failing, while they still see each
# other cleanly. That asymmetry is what the failure-detector experiment
# tests. See README for the full procedure.

set -o errexit
set -o nounset
set -o pipefail

readonly default_iface="eth0"

show_usage() {
    cat << EOF
Usage: $0 <node> <loss-percent> [iface]

Applies "tc qdisc replace dev <iface> root netem loss <percent>%" inside
the given compose service, dropping that fraction of outbound packets.

Arguments:
  node          compose service name (e.g. rmq0)
  loss-percent  integer 0-100
  iface         network interface (default: $default_iface)

Examples:
  $0 rmq0 48
  $0 rmq0 48 eth0
EOF
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

    local -r node="$1"
    local -r loss="$2"
    local -r iface="${3:-$default_iface}"

    if ! [[ "$loss" =~ ^[0-9]+$ ]] || (( loss > 100 ))
    then
        echo "Error: loss-percent must be an integer 0-100, got '$loss'" >&2
        exit 1
    fi

    echo "Applying ${loss}% egress loss on $node ($iface)" >&2
    docker compose exec -T "$node" \
        tc qdisc replace dev "$iface" root netem loss "${loss}%" < /dev/null

    echo "Current qdisc on $node:" >&2
    docker compose exec -T "$node" tc qdisc show dev "$iface" < /dev/null
}

main "$@"
