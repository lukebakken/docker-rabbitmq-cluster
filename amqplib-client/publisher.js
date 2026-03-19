'use strict';

const amqplib = require('amqplib');

const AMQP_URL = process.env.AMQP_URL || 'amqp://guest:guest@localhost:5672';
const EXCHANGE = 'events-exchange';
const QUEUE = 'notification-service';
const ROUTING_KEY = 'entity.updated';

// A realistic-looking header set. The x-payload field simulates a value that
// "got away" - e.g. a serialized context object placed in headers instead of
// the message body. Adjust PAYLOAD_SIZE to control whether the total encoded
// header size exceeds the amqplib default frameMax of 4096 bytes.
const PAYLOAD_SIZE = parseInt(process.env.PAYLOAD_SIZE || '4000', 10);

async function main() {
    const conn = await amqplib.connect(AMQP_URL + '?frameMax=0');
    const ch = await conn.createChannel();

    await ch.assertExchange(EXCHANGE, 'topic', { durable: true });
    await ch.assertQueue(QUEUE, { durable: true });
    await ch.bindQueue(QUEUE, EXCHANGE, ROUTING_KEY);

    const headers = {
        'x-trace-id': 'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
        'x-span-id': 'b2c3d4e5-f6a7-8901-bcde-f12345678901',
        'x-correlation-id': 'c3d4e5f6-a7b8-9012-cdef-123456789012',
        'x-service': 'events-service',
        'x-routing-key': ROUTING_KEY,
        'x-payload': 'x'.repeat(PAYLOAD_SIZE),
    };

    const body = Buffer.from(JSON.stringify({ entityId: 'v-12345', status: 'completed' }));

    conn.on('error', err => {
        console.error(`Connection error: ${err.message}`);
    });

    ch.publish(EXCHANGE, ROUTING_KEY, body, {
        persistent: true,
        contentType: 'application/json',
        headers,
    });

    const totalHeaderBytes = Buffer.byteLength(JSON.stringify(headers));
    console.log(`Published message to ${EXCHANGE} -> ${ROUTING_KEY}`);
    console.log(`  x-payload size : ${PAYLOAD_SIZE} bytes`);
    console.log(`  approx headers : ${totalHeaderBytes} bytes`);
    console.log(`  amqplib frameMax: ${conn.connection.frameMax} bytes`);

    await ch.close();
    await conn.close();
}

main().catch(err => {
    console.error('Publisher error:', err.message);
    process.exit(1);
});
