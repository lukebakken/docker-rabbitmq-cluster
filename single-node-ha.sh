#!/usr/bin/env bash

script_dir="$(CDPATH='' cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P)"
readonly script_dir

set -o errexit
set -o nounset
set -o pipefail

declare -r queue="${1:-ha-queue-0-0}"

"$script_dir/rabbitmqadmin" declare operator_policy "name=ha-single-$queue" "pattern=^$queue$" 'apply-to=queues' 'definition={"ha-mode":"exactly","ha-params":1,"ha-sync-mode":"automatic"}' priority=99
