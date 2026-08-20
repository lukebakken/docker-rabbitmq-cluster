# aten failure-detector packet-loss experiment

## Purpose

RabbitMQ ships `aten`, the adaptive accrual failure detector that `ra` (and therefore quorum queues) uses to decide when a peer node is unreachable. `aten` heartbeats every Erlang-connected node every 100ms and tracks each peer's heartbeat inter-arrival times; `aten_sink:get_failure_probabilities/0` returns a map of `peer -> probability` where 0.0 is healthy and 1.0 means the peer is considered down.

The question this experiment answers: when a single node has a network fault (a physical-host or uplink defect that drops a large fraction of that node's packets in both directions), can `aten`'s per-node failure probabilities identify *which* node is faulty, early and unambiguously, from the healthy nodes' point of view? And does that signal survive cluster-wide network congestion, which perturbs every node's heartbeats at once?

This matters because `aten` is per-node, real-time, packet-loss-sensitive, and already running on every node. If its probabilities can attribute a fault to a specific node, they are a candidate early-detection signal for a faulty node that reachability-based health checks miss.

## Background: how aten produces the signal

- `aten_emitter` sends a heartbeat to every connected node (`nodes()`) every 100ms, unconditionally. It does not require any `ra`/quorum-queue registration, so on a running cluster every node has heartbeat data for every peer even with no quorum queues in use.
- `aten_sink` records per-peer heartbeat inter-arrival samples and exposes `get_failure_probabilities/0`, returning `#{peer => probability}`.
- `aten_detect` computes the probability from the samples; `aten_detector` polls once per second and fires `{node_event, Node, up | down}` at a probability threshold of 0.99. Only those up/down events reach `ra`; the continuous probability is not surfaced anywhere by default.
- The heartbeats travel over the Erlang distribution channel, so interface-level packet loss degrades exactly the signal `aten` measures.

The directed nature of the data is important: `observer -> peer` probability is driven by the heartbeats arriving at `observer` from `peer`, i.e. by `peer`'s outbound path (plus `observer`'s inbound path). Egress loss on one node therefore shows up in that node's peers' view of it.

## Environment

- 3-node cluster, RabbitMQ 3.13.7, classic mirrored queues with `ha-mode: all` and a quorum-queue workload alongside.
- Docker Compose, one container per node, `mem_limit: 8g` each, bridge network.
- Nodes carry the `NET_ADMIN` capability and the image installs `iproute2` (for `tc`/netem) and `iptables`.
- Interface inside each container is `eth0`.

## Tooling

All under `netem/` (see the repo `Makefile` for thin wrappers: `inject`, `inject-periodic`, `clear`, `capture`):

- `loss.sh <node> <pct>` applies steady egress packet loss on a node via `tc qdisc replace dev eth0 root netem loss <pct>%`.
- `loss-periodic.sh <node> <pct> <on> <off>` toggles egress loss on and off in intervals to model periodic drops; it clears the qdisc on exit via a trap.
- `clear.sh <node>` removes the qdisc.
- `capture-aten.sh <secs> <interval>` polls `aten_sink:get_failure_probabilities/0` on all nodes every `interval` seconds and writes one timestamped line per observer to `out/aten-capture.log`.

Loss is injected egress-only. Dropping a node's outbound heartbeats makes its peers see it as failing, which is the attribution signal under test. Egress-only is sufficient to reproduce the attribution behaviour; a fully bidirectional model of a host defect would additionally add ingress loss (via an `ifb` device) and was not needed here.

## Experiment 1: single faulty node under load

Method: bring the cluster up under mirrored-queue plus quorum-queue load, start `capture-aten.sh`, then inject periodic 48% egress loss on one node (`ON 5s / OFF 10s`) for several minutes while capturing every node's probabilities at 1Hz.

Result (attribution is clean and early):

- The mutually-clean pair (the two healthy nodes' view of each other) stayed at exactly 0.000 for the entire run.
- Both healthy nodes independently drove the faulty node's probability high (means around 0.57-0.59, maxima 1.0), converging on the same culprit within seconds.
- The probability flapped with the loss duty cycle: roughly 0.2-0.4 during the OFF window (decaying) and around 0.99 during the ON window, on the 15s period. It exceeded 0.9 in about 39-40% of samples, tracking the ON duty cycle plus the detection and decay tail.
- The faulty node's own view of its peers stayed low (mean around 0.056), as expected for egress-only loss.
- `ra` corroboration: the healthy nodes logged quorum-queue pre-vote timeouts naming the faulty node as possibly down, i.e. `aten`'s down events propagating into `ra`.

Detector implication: the right signal is time-above-a-low-threshold or flap-rate, not an instantaneous probability of 0.99 (which is absent roughly 60% of the time under periodic loss).

## Experiment 2: cluster-wide congestion (masking)

The concern from the field is that heavy cluster-wide network congestion perturbs every node's heartbeats at once, which could mask the one genuinely-faulty node. `busy_dist_port` (Erlang distribution buffer saturation) is the field symptom of that congestion, but it could not be reproduced on single-host Docker: the loopback drains the distribution buffer faster than load fills it, so even 100KB mirrored messages over a deliberately-shrunk distribution buffer (`+zdbbl 32`) did not trip it. Congestion was therefore modelled directly at the signal level, by applying uniform egress loss to all nodes to elevate every node's heartbeat variance, then making one node worse.

Method: baseline with no loss, then uniform 4% egress loss on all three nodes, then raise one node to 25% while the others stay at 4%, then clear. Capture at 1Hz throughout.

Result (attribution survives, but only as a relative signal):

| Phase | healthy A -> faulty | healthy B -> faulty | clean pair (A <-> B) |
|---|---|---|---|
| baseline (no loss) | 0.000 | 0.000 | 0.000 / 0.000 |
| uniform 4% all | 0.434 | 0.799 | 0.080 / 0.096 |
| faulty 25%, others 4% | 0.945 | 0.999 | 0.114 / 0.163 |

- The genuinely-faulty node is still the clear maximum from both observers, with a large margin over the clean pair (about 0.95-1.0 versus 0.11-0.16). Ranking plus a margin across multiple observers still attributes correctly.
- The crisp "clean pair equals 0.000" rule from Experiment 1 does not hold under background congestion: the clean pair sits at 0.08-0.16, so an absolute near-zero threshold would false-trip.
- There is a pre-existing node and observer asymmetry: even under uniform loss the busiest node (more queue masters, load-balancer target) already reads elevated (0.43-0.80), with no special fault. A naive detector risks false-positives on the busiest node.

Detector implication: attribution must be comparative (compare nodes against each other and require a margin), never an absolute cutoff, and must use hysteresis or flap-rate to tolerate the noisy, asymmetric baseline that cluster-wide congestion produces.

## Operational finding: cluster-wide loss can OOM a node

During the heavier-loss runs, a node's `beam.smp` was killed by the kernel cgroup OOM-killer at roughly 8 GB anon-rss, against the container's 8 GB `mem_limit`. Under packet loss on an `ha-mode: all` cluster with persistent messages, delivery and acknowledgements stall while publishers keep filling the mirrored queues, so message backlog accumulates in memory until `beam` exceeds the limit and is killed. Docker Compose then replaces the dead container with a fresh one, so the replacement shows `OOMKilled=false` and `RestartCount=0`; the OOM is only visible in the kernel log (`dmesg`) and on the now-removed container. Gentler loss with smaller messages avoided it (all three nodes survived Experiment 2's clean run).

## Reproducing

For the literal command sequence actually used (including the ad-hoc load containers, the `+zdbbl` dead-end, and the raw `tc` orchestration), see [exact-commands.md](exact-commands.md). The tidy version using the `make` wrappers is below.

```
# Bring the cluster up (perf-test load starts automatically).
make up

# Experiment 1: capture in one shell, inject periodic loss in another.
make capture SECS=240 INTERVAL=1
make inject-periodic NODE=rmq0 LOSS=48 ON=5 OFF=10
make clear NODE=rmq0

# Experiment 2 (masking): uniform loss on all nodes, then make one worse.
make inject NODE=rmq0 LOSS=4
make inject NODE=rmq1 LOSS=4
make inject NODE=rmq2 LOSS=4
# then, after a baseline window:
make inject NODE=rmq0 LOSS=25
# then clear each node:
make clear NODE=rmq0
make clear NODE=rmq1
make clear NODE=rmq2
```

Captured probabilities land in `out/aten-capture.log`, one timestamped line per observer per sample: `<iso-8601> observer=<node> #{peer => probability, ...}`.

Notes:

- Keep messages small or loss moderate to avoid OOM-killing a node under `ha-mode: all` (see the operational finding above).
- `+zdbbl` can be lowered via `RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS` to shrink the distribution buffer, but this did not reproduce `busy_dist_port` on single-host loopback and can destabilise boot-time cluster formation at very small values.
