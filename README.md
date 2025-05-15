<!-- vim:tw=80
-->
## Shrink CMQ to one node

### Bring up cluster

```
make up
```

### Set up policy and some queues

```
./setup.sh
```

### Start PerfTest (optional)

Note: this is running PerfTest compiled from source
(https://github.com/rabbitmq/rabbitmq-perf-test.git). The following command will
ensure that ready messages keeps growing in the `ha-queue-0-0` queue.

```
make ARGS='--producers 1 --consumers 1 --predeclared --queue ha-queue-0-0 --auto-delete false --rate 5 --consumer-rate 1' run
```

You should see messages ready increasing in the `ha-queue-0-0` queue, if you've
run PerfTest.

### Observe

At this point, there are several `ha-mode: all` classic queues.

### Shrink / grow

```
./shrink-grow.sh
```

This script does the following:
* Gets information about the nodes in the cluster.
* Gets the current queue leader node for the `ha-queue-0-0` queue.
* Adds a new, higher-priority operator policy that only matches the
`ha-queue-0-0` queue, and specifies a node that is _not_ the current leader as
the only node to host the queue (no slaves).
* Asks for input so you can check that the leader has moved.
* Removes the temporary policy at the end.

### Single node before shrink/grow

To observe what happens if a CMQ with _no_ synchronized slaves is moved, run the
`single-node-ha.sh` script prior to running `shrink-grow.sh`. The
`single-node-ha.sh` script will force the node to only run on one node. Then,
you can observe that `shrink-grow.sh` has no ill effects when
producers/consumers are running against it.
