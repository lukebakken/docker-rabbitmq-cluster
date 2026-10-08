## Bring up a cluster

```
make up
```

## Clean data:

```
make clean
```

## Test a rolling upgrade

`RABBITMQ_UPGRADE_FROM_DOCKER_TAG` is the version the cluster starts on, `RABBITMQ_UPGRADE_DOCKER_TAG` the version it ends on. Both are separate from the `RABBITMQ_DOCKER_TAG` that plain `make up` uses, so that `make up` does not default to the older release and rebuild an already-upgraded cluster onto it.

If another container on the host already holds 5672 or 15672, export the override that drops haproxy's published ports before anything else. Each node's management UI is still reachable on its own published port, and `docker-compose.yml` is where those are set:

```
export COMPOSE_FILE=docker-compose.yml:upgrade-test.override.yml
```

Bring up the cluster on the old version, enable every feature flag, then roll each node onto the new one:

```
make upgrade-from
make enable-ff
make upgrade
```

`make upgrade-from` brings the cluster up detached, because plain `make up` runs `docker compose up` attached and would never return. Use a second terminal instead if you want the logs, and export `COMPOSE_FILE` in both.

Downgrades are not supported, and the data directories under `data/` outlive the containers. An old node cannot apply the newer Khepri machine version its predecessor wrote, so it reports `Up`, never becomes ready, and says so only at debug level. If that happens, bring the cluster back up on the newer tag; nothing is lost.

`make enable-ff` is not optional, and `upgrade.sh` aborts while any flag is still disabled. The Dockerfile sets `RABBITMQ_FEATURE_FLAGS=khepri_db`, so a new node enables that flag and the required ones but no other stable flag, whereas 4.3.0 requires every flag introduced in 4.2.0 or earlier. Run it again after the upgrade to pick up the flags that are new in the version you upgraded to.

`make upgrade` drains, stops and restarts one node at a time, then rebalances leaders and checks that every node reports `RABBITMQ_EXPECTED_VERSION`, which defaults to the version in `RABBITMQ_UPGRADE_DOCKER_TAG`. That check is what makes a restart that upgraded nothing fail rather than print success.
