# TODO

## Queue federation has the same #11495 exposure (fix is exchange-only)

The committed fix (`rabbit_federation_exchange:recover_links/0` boot step) covers
**exchange** federation only. Queue federation has the identical `New == Old` gate:
`rabbit_queue_decorator:maybe_recover/1` only calls `startup/1` ->
`rabbit_federation_queue_link_sup_sup:start_child/1` when decorators changed, and it
uses the same `mirrored_supervisor` / `ram_copies` roster
(`rabbit_federation_queue_link_sup_sup`). So a rolling restart would strand
queue-federation links the same way.

NOT yet done, and deliberately not blindly patched:
- Reproduce the queue-side strand first (add *federated queues* to the repro topology;
  current topology is exchange-federation only) before writing a fix — verify then fix.
- If confirmed, add a parallel `recover_links/0` boot step in `rabbit_federation_queue`
  (mirroring the exchange fix), and a `start_child_status/1` in
  `rabbit_federation_queue_link_sup_sup`.
- Open question: does Amazon MQ / the b-8a4cc67f customer actually use queue federation?
  The incident was exchange federation; queue-side may be latent-only for this customer.

## Latest RabbitMQ (4.2 main) is still affected — verified in source 2026-07-09

Checked `/home/lrbakken/development/rabbitmq/rabbitmq-server` @ `abfa23b089`
(`v4.2.0-beta.4-2188`, main). In 4.2 the federation plugins were split into
`rabbitmq_exchange_federation`, `rabbitmq_queue_federation`, and
`rabbitmq_federation_common`, but the #11495 mechanism is intact:

- **Strand gate still present.** `rabbit_exchange_decorator:maybe_recover/1`
  (`deps/rabbit/src/rabbit_exchange_decorator.erl:107-117`) still has the exact
  `case New of Old -> ok` short-circuit; `rabbit_queue_decorator:maybe_recover/1`
  (`rabbit_queue_decorator.erl:63-77`) has the identical gate. The dead-pid
  self-heal still lives only inside `start_child`/`create_or_update`, reached
  only when the gate is NOT taken.
- **No reconcile boot step upstream.** `rabbit_federation_exchange.erl` in 4.2 has
  only the decorator-registration boot step (`{requires,[rabbit_registry,recovery]}`)
  — no roster-reconcile step like our fix. So upstream has NOT closed the strand;
  the fix's mechanism is still needed on main.
- **Queue federation confirmed same exposure on 4.2.** `rabbit_federation_queue.erl:33`
  drives `rabbit_federation_queue_link_sup_sup:start_child/1`, and that sup_sup is a
  `mirrored_supervisor` (`rabbit_federation_queue_link_sup_sup.erl:10`) — same
  ram_copies roster + same gate. This upgrades the "Queue federation" section above
  from inference to source-verified against latest.

Deferred (not started): porting the reconcile fix to 4.2 main (both exchange and
queue federation) and validating there. The 3.13.7 fix branch stands on its own for
the customer's broker; a 4.2 port is a separate upstream contribution.

## Orphaned-internal-queue behavior on 4.2 (unset cluster_name) — verified, benign

`upstream_queue_name/3` in 4.2 (`deps/rabbitmq_exchange_federation/src/rabbit_federation_exchange_link.erl:742-753`)
STILL embeds `rabbit_nodes:cluster_name()` in the internal queue name
(`"federation: <X> -> <cluster_name>:<vhost>:<X>"`), and `cluster_name()` still
defaults to the node name when unset (`rabbit_nodes:cluster_name_default/0`). So the
same node-name-rotation-on-migration behavior exists on latest. This is NOT a broker
bug — it is benign whenever `cluster_name` is set (as on the customer's broker,
`RetailPlatform`, and now on this harness via `rmq/rabbitmq.conf`). It only produced
consumerless orphan queues in this harness because cluster_name was unset.

Documentation decision (2026-07-09): keep this documented HERE (repro TODO.md) and in
the harness memory only. It is a harness-config gotcha, not a customer-facing defect
and not worth an upstream issue. The `rmq/rabbitmq.conf` comment already records the
"why"; the count_internal_queues / restart_loop comments in `scripts/repro-lib.sh`
explain that a non-1:1 internal-queue count is this artifact, not the #11495 strand.

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
