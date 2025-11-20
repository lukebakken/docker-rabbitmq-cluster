package com.mycompany.app;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import java.util.stream.IntStream;

import com.rabbitmq.stream.Address;
import com.rabbitmq.stream.Consumer;
import com.rabbitmq.stream.Environment;
import com.rabbitmq.stream.Producer;

public class App {
    private static final AtomicBoolean isRunning = new AtomicBoolean(true);
    private static final AtomicLong totalSent = new AtomicLong(0);
    private static final AtomicLong totalConsumed = new AtomicLong(0);
    private static final List<Environment> environments = new ArrayList<>();
    private static final List<Producer> producers = new ArrayList<>();
    private static final List<Consumer> consumers = new ArrayList<>();
    private static final int NUM_PRODUCERS = 2;
    private static final int NUM_CONSUMERS = 5;

    public static void main(String[] args) throws Exception {
        System.out.println("Application starting, registering signal handlers...");

        // Register shutdown hook
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            System.out.println("Shutdown signal received, initiating cleanup...");
            isRunning.set(false);
            cleanup();
        }));

        run();
    }

    private static void run() throws Exception {
        String user = "guest";
        String password = "guest";
        String host = System.getenv().getOrDefault("RABBITMQ_HOST", "localhost");
        int port = Integer.parseInt(System.getenv().getOrDefault("RABBITMQ_PORT", "5552"));

        Address entryPoint = new Address(host, port);

        // Create initial environment for stream creation
        Environment initialEnv = null;
        int retryCount = 0;
        int maxRetries = 10;
        int retryDelaySeconds = 5;

        while (initialEnv == null && retryCount < maxRetries) {
            try {
                System.out.println("Attempting to connect to RabbitMQ (attempt " + (retryCount + 1) + "/" + maxRetries + ")...");
                initialEnv = Environment.builder()
                        .addressResolver(address -> entryPoint)
                        .host(host)
                        .port(port)
                        .username(user)
                        .password(password)
                        .build();
                System.out.println("Successfully connected to RabbitMQ");
            } catch (Exception ex) {
                retryCount++;
                if (retryCount >= maxRetries) {
                    System.out.println("Failed to connect after " + maxRetries + " attempts. Exiting.");
                    throw ex;
                }
                System.out.println("Connection failed: " + ex.getMessage() + ". Retrying in " + retryDelaySeconds + " seconds...");
                Thread.sleep(retryDelaySeconds * 1000);
            }
        }

        // Create the stream
        initialEnv.streamCreator().stream("java-stream-client-app").create();
        initialEnv.close();

        // Create producers with separate environments
        for (int i = 0; i < NUM_PRODUCERS; i++) {
            Environment env = Environment.builder()
                    .addressResolver(address -> entryPoint)
                    .host(host)
                    .port(port)
                    .username(user)
                    .password(password)
                    .clientProperty("connection_name", "rabbitmq-stream-producer-" + i)
                    .build();
            environments.add(env);

            Producer producer = env.producerBuilder()
                    .stream("java-stream-client-app")
                    .name("producer_" + i)
                    .build();
            producers.add(producer);
        }

        // Create consumers with separate environments
        for (int i = 0; i < NUM_CONSUMERS; i++) {
            Environment env = Environment.builder()
                    .addressResolver(address -> entryPoint)
                    .host(host)
                    .port(port)
                    .username(user)
                    .password(password)
                    .clientProperty("connection_name", "rabbitmq-stream-consumer-" + i)
                    .build();
            environments.add(env);

            Consumer consumer = env.consumerBuilder()
                    .stream("java-stream-client-app")
                    .name("consumer_" + i)
                    .messageHandler((ctx, msg) -> {
                        totalConsumed.incrementAndGet();
                    })
                    .build();
            consumers.add(consumer);
        }

        // Start summary logging thread
        Thread summaryThread = new Thread(() -> {
            while (true) {
                try {
                    Thread.sleep(5000);
                    System.out.println(String.format("Sent: %,d, Consumed: %,d",
                        totalSent.get(), totalConsumed.get()));
                } catch (InterruptedException e) {
                    break;
                }
            }
        });
        summaryThread.start();

        System.out.println("Starting continuous message publishing...");

        // Start producer threads
        List<Thread> producerThreads = new ArrayList<>();
        for (int i = 0; i < NUM_PRODUCERS; i++) {
            final int producerId = i;
            final Producer producer = producers.get(i);
            Thread producerThread = new Thread(() -> {
                long messageId = 0;
                while (isRunning.get()) {
                    try {
                        producer.send(
                                producer.messageBuilder()
                                        .addData(String.valueOf(messageId).getBytes())
                                        .build(),
                                confirmationStatus -> {
                                    totalSent.incrementAndGet();
                                });
                        messageId++;
                        Thread.sleep(100);
                    } catch (InterruptedException e) {
                        break;
                    }
                }
            });
            producerThread.start();
            producerThreads.add(producerThread);
        }

        // Wait for producer threads to finish
        for (Thread thread : producerThreads) {
            thread.join();
        }
    }

    private static void cleanup() {
        try {
            System.out.println("Waiting for in-flight messages...");
            long timeout = 10000; // 10 seconds
            long start = System.currentTimeMillis();
            while (totalSent.get() > totalConsumed.get() &&
                   (System.currentTimeMillis() - start) < timeout) {
                Thread.sleep(100);
            }
            System.out.println(String.format("Messages: Sent=%,d, Consumed=%,d",
                totalSent.get(), totalConsumed.get()));

            System.out.println("Closing producers...");
            for (Producer producer : producers) {
                producer.close();
            }

            System.out.println("Closing consumers...");
            for (Consumer consumer : consumers) {
                consumer.close();
            }

            System.out.println("Closing environments...");
            for (Environment env : environments) {
                env.close();
            }

            System.out.println("Cleanup complete");
        } catch (Exception e) {
            System.err.println("Error during cleanup: " + e.getMessage());
        }
    }
}
