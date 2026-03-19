'use strict';

const amqplib = require('amqplib');

const AMQP_URL = process.env.AMQP_URL || 'amqp://guest:guest@localhost:5672';
const EXCHANGE = 'events-exchange';
const QUEUE = 'notification-service';
const ROUTING_KEY = 'entity.updated';
const RECONNECT_DELAY_MS = 2000;

async function consume() {
    let conn;
    try {
        conn = await amqplib.connect(AMQP_URL);
        console.log(`Connected (frameMax: ${conn.connection.frameMax} bytes)`);

        conn.on('error', err => {
            console.error(`Connection error: ${err.stack}`);
        });

        conn.on('close', () => {
            console.log(`Connection closed. Reconnecting in ${RECONNECT_DELAY_MS}ms...`);
            setTimeout(consume, RECONNECT_DELAY_MS);
        });

        const ch = await conn.createChannel();

        await ch.assertExchange(EXCHANGE, 'topic', { durable: true });
        await ch.assertQueue(QUEUE, { durable: true });
        await ch.bindQueue(QUEUE, EXCHANGE, ROUTING_KEY);

        console.log(`Consuming from ${QUEUE}...`);

        ch.consume(QUEUE, msg => {
            if (msg === null) return;
            console.log(`Received message: ${msg.content.toString()}`);
            ch.ack(msg);
        });

    } catch (err) {
        console.error(`Failed to connect: ${err.message}`);
        console.log(`Retrying in ${RECONNECT_DELAY_MS}ms...`);
        setTimeout(consume, RECONNECT_DELAY_MS);
    }
}

consume();
