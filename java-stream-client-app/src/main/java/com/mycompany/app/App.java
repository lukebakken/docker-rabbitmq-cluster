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
        String host = "localhost";

        Address entryPoint = new Address(host, 5552);

        Environment environment = Environment.builder()
                .addressResolver(address -> entryPoint) // Use a load balancer
                .host(host)
                .port(5552)
                .username(user)
                .password(password)
                .build();

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
