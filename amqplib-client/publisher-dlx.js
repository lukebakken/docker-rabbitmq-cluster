'use strict';

const amqplib = require('amqplib');

const AMQP_URL = process.env.AMQP_URL || 'amqp://guest:guest@localhost:5672';

// Topology: hub-and-spoke retry pattern with 20 TTL buckets.
//
// The consumer nacks each delivery, which dead-letters to retry-exchange.
// The consumer sets x-next-bucket on the message so retry-exchange routes
// to the correct TTL bucket. After the TTL expires, retry-output-exchange
// routes the message back to the work queue.
//
// Each pass through a unique bucket adds one entry to the x-death array
// (deduplication key is {queue, reason}, so each unique queue name = new entry).
// With 20 buckets and ~200 bytes per entry, the array exceeds 4096 bytes
// after one full cycle, triggering "Frame size exceeds frame max" on the
// consumer (which uses the default frameMax of 4096 bytes).

const WORK_EXCHANGE = 'work-exchange';
const RETRY_EXCHANGE = 'retry-exchange';
const RETRY_OUTPUT_EXCHANGE = 'retry-output-exchange';
const WORK_QUEUE = 'order-processor';
const ROUTING_KEY = 'order.created';

const RETRY_BUCKETS = Array.from({ length: 20 }, (_, i) => ({
    name: `retry-order-processing-service-worker-aggregation-results-bucket-v2-${String(i + 1).padStart(2, '0')}`,
    ttl: (i + 1) * 500,
}));

async function main() {
    const conn = await amqplib.connect(AMQP_URL + '?frameMax=0');
    const ch = await conn.createChannel();

    conn.on('error', err => {
        console.error(`Connection error: ${err.message}`);
    });

    await ch.assertExchange(WORK_EXCHANGE, 'topic', { durable: true });
    await ch.assertExchange(RETRY_EXCHANGE, 'topic', { durable: true });
    await ch.assertExchange(RETRY_OUTPUT_EXCHANGE, 'topic', { durable: true });

    await ch.assertQueue(WORK_QUEUE, {
        durable: true,
        arguments: { 'x-dead-letter-exchange': RETRY_EXCHANGE },
    });
    await ch.bindQueue(WORK_QUEUE, WORK_EXCHANGE, ROUTING_KEY);
    await ch.bindQueue(WORK_QUEUE, RETRY_OUTPUT_EXCHANGE, ROUTING_KEY);

    for (const bucket of RETRY_BUCKETS) {
        await ch.assertQueue(bucket.name, {
            durable: true,
            arguments: {
                'x-message-ttl': bucket.ttl,
                'x-dead-letter-exchange': RETRY_OUTPUT_EXCHANGE,
                'x-dead-letter-routing-key': ROUTING_KEY,
            },
        });
        await ch.bindQueue(bucket.name, RETRY_EXCHANGE, bucket.name);
    }

    const body = Buffer.from(JSON.stringify({ orderId: 'ord-12345', amount: 99.99 }));
    ch.publish(WORK_EXCHANGE, ROUTING_KEY, body, {
        persistent: true,
        contentType: 'application/json',
        headers: { 'x-next-bucket': 0 },
    });

    console.log(`Published message to ${WORK_EXCHANGE} -> ${ROUTING_KEY}`);
    console.log(`Retry chain: ${RETRY_BUCKETS.length} buckets, ` +
                `${RETRY_BUCKETS[0].ttl}ms - ${RETRY_BUCKETS[RETRY_BUCKETS.length - 1].ttl}ms TTL`);
    console.log(`One full cycle takes ~${RETRY_BUCKETS.reduce((s, b) => s + b.ttl, 0) / 1000}s`);

    await ch.close();
    await conn.close();
}

main().catch(err => {
    console.error('Publisher error:', err.message);
    process.exit(1);
});
