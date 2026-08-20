## Bring up a cluster

```
make up
```

## Clean data:

```
make clean
```

## Failure-detector experiment

Injects packet loss on cluster nodes and captures `aten` per-node failure probabilities to test whether a single faulty node can be attributed from its healthy peers. Requires `NET_ADMIN` (granted in `docker-compose.yml`) and `tc` (installed via `iproute2`).

```
make up                                              # cluster + perf-test load
make capture SECS=240 INTERVAL=1                     # poll aten on all nodes -> out/
make inject-periodic NODE=rmq0 LOSS=48 ON=5 OFF=10   # periodic egress loss on one node
make clear NODE=rmq0                                 # restore clean networking
```

Findings in brief:

- With one faulty node and no other congestion, the two healthy nodes' view of each other stays at 0.000 while both peg the faulty node near 1.0: attribution is clean and early, and the probability flaps with the loss duty cycle (so use flap-rate or time-above-threshold, not an instantaneous 0.99).
- Under cluster-wide loss the faulty node still ranks highest from both peers by a wide margin, but the clean pair is no longer 0.000 and the busiest node reads elevated even with no fault: attribution must be comparative with a margin, never an absolute cutoff.
- Under `ha-mode: all` with persistent messages, sustained loss can OOM-kill a node (backlog fills memory to the 8 GB container limit); keep messages small or loss moderate.

Full methodology and results: [docs/aten-experiment.md](docs/aten-experiment.md).
