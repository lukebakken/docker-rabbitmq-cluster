#!/usr/bin/env bash

# Remove any netem qdisc from one node's interface, restoring clean networking.

set -o errexit
set -o nounset
set -o pipefail

readonly default_iface="eth0"

show_usage() {
    cat << EOF
Usage: $0 <node> [iface]

Runs "tc qdisc del dev <iface> root" inside the given compose service.
A missing qdisc is not treated as an error.

Arguments:
  node   compose service name (e.g. rmq0)
  iface  network interface (default: $default_iface)
EOF
}

main() {
    case "${1:-}" in
        --help|-h)
            show_usage
            exit 0
            ;;
    esac

    if (( $# < 1 ))
    then
        show_usage
        exit 1
    fi

    local -r node="$1"
    local -r iface="${2:-$default_iface}"

    echo "Clearing netem qdisc on $node ($iface)" >&2
    if docker compose exec -T "$node" \
        tc qdisc del dev "$iface" root < /dev/null 2>/dev/null
    then
        echo "Cleared." >&2
    else
        echo "No root qdisc to clear (already clean)." >&2
    fi
}

main "$@"
