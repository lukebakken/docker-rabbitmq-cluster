# docker-rabbitmq-cluster

A 3-node RabbitMQ 3.13 cluster running in Docker, with an amqplib client
reproducer for the "Frame size exceeds frame max" error.

## Cluster

### Start

```
make up
```

### Stop

```
make down
```

### Clean data

```
make clean
```

The cluster consists of three RabbitMQ nodes (`rmq0`, `rmq1`, `rmq2`) behind
an HAProxy load balancer. Ports exposed on the host:

| Port  | Service                        |
|-------|--------------------------------|
| 5672  | AMQP (via HAProxy)             |
| 15672 | Management UI (via HAProxy)    |
| 8872  | Management UI (rmq0 direct)    |
| 8873  | Management UI (rmq1 direct)    |
| 8874  | Management UI (rmq2 direct)    |

## Reproducer: "Frame size exceeds frame max"

### Background

The AMQP 0-9-1 protocol splits messages into three frame types: method,
header, and body. Body frames can be split across multiple frames to fit
within the negotiated `frameMax` limit. Header frames cannot - the protocol
has no provision for fragmenting them. If the encoded size of a message's
properties and headers exceeds `frameMax`, the broker sends an oversized
header frame and the client throws:

```
Error: Frame size exceeds frame max
```

`amqplib` versions prior to 0.10.6 default `frameMax` to 4096 bytes (4 KB).
In 0.10.6 the default was raised to 131072 bytes to match the broker's
advertised value.

### Topology

The reproducer mimics the topology involved in a real incident:

- Exchange: `events-exchange` (topic, durable)
- Queue: `notification-service` (durable)
- Binding: routing key `entity.updated`

### Reproduce the error (broken - amqplib 0.10.1)

In one terminal, start the consumer:

```
make run-consumer
```

In another terminal, publish a message with headers exceeding 4096 bytes:

```
make run-publisher
```

The consumer will log the error and reconnect repeatedly. Because the message
is never acked, RabbitMQ redelivers it on each reconnect, cycling indefinitely:

```
Connected (frameMax: 4096 bytes)
Consuming from notification-service...
Connection error: Error: Frame size exceeds frame max
    at parseFrame (.../amqplib/lib/frame.js:55:13)
    at C.recvFrame (.../amqplib/lib/connection.js:613:15)
    at Socket.go (.../amqplib/lib/connection.js:486:30)
    ...
Connection closed. Reconnecting in 2000ms...
```

The publisher connects with `frameMax=0` (unlimited) so it can successfully
send the oversized header frame to the broker. The consumer connects with the
default `frameMax=4096`, so when the broker delivers the message it throws.
This mirrors the real-world scenario where the publisher and consumer are
different processes that may negotiate different `frameMax` values.

The `PAYLOAD_SIZE` environment variable controls the size of the `x-payload`
header field (default: 4000 bytes). Combined with the other headers, the total
encoded size exceeds the 4096-byte frameMax:

```
PAYLOAD_SIZE=4000 make run-publisher   # triggers the error
PAYLOAD_SIZE=100 make run-publisher    # stays under the limit
```

### Demonstrate the fix (amqplib 0.10.6+)

Switch to the fixed amqplib version:

```
make use-fixed
```

Then run the consumer and publisher as above. The consumer receives the
message cleanly because amqplib 0.10.6 defaults `frameMax` to 131072 bytes:

```
Connected (frameMax: 131072 bytes)
Consuming from notification-service...
Received message: {"entityId":"v-12345","status":"completed"}
```

To switch back to the broken version:

```
make use-broken
```

### npm install

The `run-publisher` and `run-consumer` targets run `npm install` automatically
if `amqplib-client/node_modules` is out of date. After `make use-fixed` or
`make use-broken`, the next `run-*` invocation will reinstall automatically.
