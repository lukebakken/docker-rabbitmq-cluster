## Bring up a cluster

```
make up
```

## Clean data:

```
make clean
```

## Reproduce rabbitmq-server #9905

A classic mirrored queue at its `max-length` with `overflow: reject-publish` leaks memory on its mirrors when a publisher that does not use confirms keeps publishing to it. See <https://github.com/rabbitmq/rabbitmq-server/issues/9905>.

`make up` starts the cluster with `publisher-noconfirm` (200 msg/s, 16 KB, no confirms) and `consumer` (100 msg/s) on `cmq-repro`, whose leader is on `rmq0`. In another terminal:

```
make watch
```

`held_msgs` and `mirror_binary_mb` grow on `rmq1` and `rmq2` and stay at zero on `rmq0`. `make stop-noconfirm` releases them.

Control, with publisher confirms: `make reset-queue`, then `docker compose --profile confirm up publisher-confirm consumer`.

With the fix: `make down`, then `CMQ_FIX=true make up`, then `make reset-queue` and `docker compose up publisher-noconfirm consumer`. `CMQ_FIX=true` compiles each module in `rmq/cmq-fix/` over the image's copy of it.

Run `make reset-queue` after any cluster restart: the restarted queue keeps its previous, dead mirror processes in its record and runs unmirrored.
