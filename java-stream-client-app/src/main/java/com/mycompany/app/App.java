package com.mycompany.app;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.stream.IntStream;

import com.rabbitmq.stream.Address;
import com.rabbitmq.stream.Environment;
import com.rabbitmq.stream.Producer;

public class App {
    public static void main(String[] args) throws Exception {
        String user = "guest";
        String password = "guest";
        String host = System.getenv().getOrDefault("RABBITMQ_HOST", "localhost");
        int port = Integer.parseInt(System.getenv().getOrDefault("RABBITMQ_PORT", "5552"));

        Address entryPoint = new Address(host, port);

        Environment environment = null;
        int retryCount = 0;
        int maxRetries = 10;
        int retryDelaySeconds = 5;

        while (environment == null && retryCount < maxRetries) {
            try {
                System.out.println("Attempting to connect to RabbitMQ (attempt " + (retryCount + 1) + "/" + maxRetries + ")...");
                environment = Environment.builder()
                        .addressResolver(address -> entryPoint) // Use a load balancer
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

        // Create the "mystream" stream
        environment.streamCreator().stream("mystream").create();

        // Create a publisher. This publisher always connects to the leader
        Producer producer = environment.producerBuilder()
                .stream("mystream")
                .build();

        // Create a consumer. This consumer is sometimes wrongly connected to the leader
        environment.consumerBuilder()
                .stream("mystream")
                .messageHandler((ctx, msg) -> {
                    System.out.println("Received message " + Long.parseLong(new String(msg.getBodyAsBinary())));
                })
                .build();

        // Publish 10 messages to confirm everything is working
        int messageCount = 10;
        CountDownLatch publishConfirmLatch = new CountDownLatch(messageCount);
        IntStream.range(0, messageCount)
                .forEach(i -> producer.send(
                        producer.messageBuilder()
                                .addData(String.valueOf(i).getBytes())
                                .build(),
                        confirmationStatus -> publishConfirmLatch.countDown()));
        publishConfirmLatch.await(10, TimeUnit.SECONDS);

        System.out.println("Done");
    }
}
