# Future Work

## Scenario 2: x-death header accumulation — IMPLEMENTED

Implemented in amqplib-client/publisher-dlx.js and consumer-dlx.js.

The reproducer uses a hub-and-spoke TTL retry pattern with 20 buckets.
Each time a message expires in a bucket, RabbitMQ appends one entry to the
x-death header (keyed by {queue, reason}). With queue names of ~70 characters,
14-15 entries is sufficient to exceed the 4096-byte frameMax, triggering
"Frame size exceeds frame max" on the consumer.

### Relationship to the customer incident

This scenario does NOT explain the customer's incident. The notification-service
queues receive messages directly from events-exchange with no
dead-letter path leading to them. Messages on those queues cannot carry x-death
headers. The customer's error was caused by large publisher-set headers, not
x-death accumulation.

This scenario is useful for demonstrating the failure mode to customers with
deep retry chains who are at risk of hitting the same error.
