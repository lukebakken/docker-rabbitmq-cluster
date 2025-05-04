#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

for svc in rmq0 rmq1 rmq2
do
    printf '[INFO] svc %s\n' "$svc"
    docker compose exec --tty "$svc" rabbitmqctl eval 'recon:bin_leak(5).'
done
