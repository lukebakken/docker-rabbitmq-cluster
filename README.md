## Bring up a cluster

```
make up
```

## Clean data:

```
make clean
```

## Failure-detector experiment

This cluster ships with `aten`, the adaptive failure detector RabbitMQ uses
under Ra. `aten` heartbeats every connected node every 100ms and tracks each
peer's heartbeat inter-arrival times; `aten_sink:get_failure_probabilities/0`
returns a map of `peer -> probability` (0.0 healthy .. 1.0 considered down).

The experiment injects packet loss on a single node and captures those
probabilities on all three nodes, to see whether a faulty node stands out to
its healthy peers early enough and clearly enough to attribute the fault.

Loss is injected egress-only on the faulty node. Dropping its outbound
heartbeats makes both healthy peers see it as failing while they still see
each other cleanly. That asymmetry (the "one mutually-clean pair" at three
nodes) is the attribution signal under test. Inject loss while the cluster is
under mirrored-queue sync load, since heavy distribution traffic can mask the
asymmetry.

Requires `NET_ADMIN` (already granted in `docker-compose.yml`) and `tc`
(installed in the image via `iproute2`).

```
# Bring the cluster up (perf-test load starts automatically).
make up

# In another shell, start capturing probabilities from all nodes.
make capture SECS=600 INTERVAL=1

# In another shell, inject periodic loss on one node.
make inject-periodic NODE=rmq0 LOSS=48 ON=5 OFF=10

# Or apply steady loss instead of periodic bursts.
make inject NODE=rmq0 LOSS=48

# Stop injecting and restore clean networking.
make clear NODE=rmq0
```

Capture output lands in `out/aten-capture.log`, one timestamped line per
observer node per sample.
