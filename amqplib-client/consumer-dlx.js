'use strict';

const amqplib = require('amqplib');

const AMQP_URL = process.env.AMQP_URL || 'amqp://guest:guest@localhost:5672';

const WORK_EXCHANGE = 'work-exchange';
const RETRY_EXCHANGE = 'retry-exchange';
const RETRY_OUTPUT_EXCHANGE = 'retry-output-exchange';
const WORK_QUEUE = 'order-processor';
const ROUTING_KEY = 'order.created';

const RETRY_BUCKETS = Array.from({ length: 20 }, (_, i) => ({
    name: `retry-order-processing-service-worker-aggregation-results-bucket-v2-${String(i + 1).padStart(2, '0')}`,
    ttl: (i + 1) * 500,
}));

// Each time a message expires in a retry bucket, RabbitMQ dead-letters it
// back to the work queue and appends one entry to the x-death header
// (keyed by {queue, reason}). With 20 unique bucket names, the array
// accumulates 20 entries (~200 bytes each), pushing the total header size
// past the consumer's frameMax of 4096 bytes.

async function consume() {
    const conn = await amqplib.connect(AMQP_URL);
    console.log(`Connected (frameMax: ${conn.connection.frameMax} bytes)`);

    conn.on('error', err => {
        console.error(`Connection error: ${err.stack}`);
    });

    conn.on('close', () => {
        console.log('Connection closed.');
    });

    const ch = await conn.createChannel();

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

    console.log(`Consuming from ${WORK_QUEUE}...`);
    console.log(`Watching x-death grow across ${RETRY_BUCKETS.length} retry buckets.`);
    console.log(`Error expected after ~${RETRY_BUCKETS.reduce((s, b) => s + b.ttl, 0) / 1000}s\n`);

    ch.consume(WORK_QUEUE, msg => {
        if (msg === null) return;

        const headers = msg.properties.headers || {};
        const xDeath = headers['x-death'] || [];
        const nextBucket = (headers['x-next-bucket'] || 0);

        console.log(`Delivery: x-death entries=${xDeath.length}, next bucket=${nextBucket + 1}/${RETRY_BUCKETS.length}`);
        if (xDeath.length > 0) {
            const last = xDeath[xDeath.length - 1];
            console.log(`  Last x-death: queue=${last.queue}, reason=${last.reason}, count=${last.count}`);
        }

        const bucket = RETRY_BUCKETS[nextBucket];
        if (!bucket) {
            // All buckets exhausted without triggering the frame error.
            // Queue names may be too short - increase name length and retry.
            console.log(`  All buckets exhausted. x-death size was insufficient to trigger the error.`);
            ch.ack(msg);
            return;
        }
        console.log(`  Routing to: ${bucket.name} (TTL: ${bucket.ttl}ms)`);

        // Ack and republish to the next retry bucket.
        // RabbitMQ will add an x-death entry when the TTL expires.
        ch.ack(msg);
        ch.publish(RETRY_EXCHANGE, bucket.name,
            msg.content,
            {
                persistent: true,
                contentType: msg.properties.contentType,
                headers: Object.assign({}, headers, { 'x-next-bucket': nextBucket + 1 }),
            }
        );
    });
}

consume().catch(err => {
    console.error('Consumer error:', err.message);
    process.exit(1);
});
