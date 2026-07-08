# TODO

## Add message load during the restart loop (deferred)

The restart loop currently exercises `make restart-loop` against an **idle**
cluster. The real #11495 incident occurred while the broker was under
substantial active load, so an idle repro may not trigger the federation-roster
stranding even with the correct graceful-drain restart path. Add a load
generator once the restart loop itself is nailed down.

### Verified load during the incident maintenance windows (2026-06-18)

Source: CloudWatch broker metrics for b-8a4cc67f, 5-minute buckets. Two graceful
drain/restart windows at 14:18-14:22 and 17:41-17:48 UTC; load measured at the
14:20-14:25 peak:

| Dimension | Incident value | Idle baseline (~08:00) |
|---|---|---|
| PublishRate | ~700-780 msg/s (peak ~980/s) | ~0.3/s |
| DeliverGetRate (consume) | ~330-395 msg/s (peak ~550/s) | ~0.5/s |
| ConnectionCount | ~1000 (peak 1798 across window) | ~633 |
| ChannelCount | ~900 | ~525 |
| MessageReadyCount (backlog) | ~2.6-3.3 million | ~2.33M |
| MessageUnacknowledgedCount | ~11-16 | - |
| ConfirmRate | 0 (confirms not in use) | 0 |

Key characteristics to reproduce:

- Publish load was **bursty and coincided with the maintenance windows** -- near
  idle most of the day, spiking to hundreds/sec exactly during the drains.
- ~1000 connections / ~900 channels were live and force-closed at each drain
  (the customer log shows ~548 "Node was put into maintenance mode" connection
  closures on one node).
- Each drain transferred leadership of ~130 quorum queues off the draining node.
- Publishing was AMQP 0.9.1 without publisher confirms (PublishRate non-zero
  while ConfirmRate is zero).

### Open question before building the generator

Broker-level metrics above are **aggregate**. Not yet confirmed: how much of the
publish/consume traffic was on the **federated exchanges** (ex0/ex1/ex2/ex3 in
the scrubbed model) versus other queues. This matters -- the stranding is about
the federation link roster, so load on the federated exchanges specifically is
what would churn it during a drain. Break this down before deciding where the
load generator should publish.

### Sketch (not started)

- Add a load-generator sidecar (e.g. `perf-test`) to `docker-compose.yml`,
  publishing to the federated exchanges at ~700 msg/s with ~900 channels /
  ~1000 connections, with consumers draining at ~350 msg/s.
- Drive it during `make restart-loop` (start before the loop, stop after).
- Gate behind a `LOAD=true` knob so the idle loop stays available for contrast.
- Confirm the load actually lands on federated exchanges (per the open question).
