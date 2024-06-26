#!/bin/bash
set -e
sleep_duration="$(((RANDOM % 10) + 1))"
echo "[INFO] $(hostname) init sleep $sleep_duration"
sleep "$sleep_duration"
exec /usr/local/bin/docker-entrypoint.sh "$@"
