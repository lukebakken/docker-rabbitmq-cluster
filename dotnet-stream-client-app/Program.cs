// This source code is dual-licensed under the Apache License, version
// 2.0, and the Mozilla Public License, version 2.0.
// Copyright (c) 2017-2023 Broadcom. All Rights Reserved. The term "Broadcom" refers to Broadcom Inc. and/or its subsidiaries.

using System.Collections.Concurrent;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Console;
using RabbitMQ.Stream.Client;
using RabbitMQ.Stream.Client.AMQP;
using RabbitMQ.Stream.Client.Reliable;

namespace Program;

public class StreamClient
{
    public record Config
    {
        public string? Host { get; set; } = "localhost";
        public int Port { get; set; } = 5552;
        public string? Username { get; set; } = "guest";
        public string? Password { get; set; } = "guest";

        public string? StreamName { get; set; } = "dotnet-stream-client-app";
        public bool LoadBalancer { get; set; } = true;
        public bool SuperStream { get; set; } = false;
        public int Streams { get; set; } = 1;
        public int Producers { get; set; } = 2;
        public byte ProducersPerConnection { get; set; } = 1;
        public int MessagesPerProducer { get; set; } = 5_000_000;
        public int Consumers { get; set; } = 10;
        public byte ConsumersPerConnection { get; set; } = 1;

        public int DelayDuringSendMs { get; set; } = 100;

        public bool EnableResending { get; set; } = false;
    }

    public static async Task Start(Config config, CancellationToken cancellationToken = default)
    {
        var serviceCollection = new ServiceCollection();
        serviceCollection.AddLogging(builder => builder
            .AddSimpleConsole(options =>
            {
                options.IncludeScopes = true;
                options.SingleLine = true;
                options.TimestampFormat = "[HH:mm:ss] ";
                options.ColorBehavior = LoggerColorBehavior.Default;
            })
            // .AddFilter("RabbitMQ.Stream.Client.StreamSystem", LogLevel.Critical)
            .AddFilter(level => level >= LogLevel.Information)
        );

        var loggerFactory = serviceCollection.BuildServiceProvider().GetService<ILoggerFactory>();

        if (loggerFactory != null)
        {
            var lp = loggerFactory.CreateLogger<Producer>();
            var lc = loggerFactory.CreateLogger<Consumer>();
            var ls = loggerFactory.CreateLogger<StreamSystem>();

            var ep = new IPEndPoint(IPAddress.Loopback, config.Port);

            if (config.Host != "localhost")
            {
                switch (Uri.CheckHostName(config.Host))
                {
                    case UriHostNameType.IPv4:
                        if (config.Host != null) ep = new IPEndPoint(IPAddress.Parse(config.Host), config.Port);
                        break;
                    case UriHostNameType.Dns:
                        if (config.Host != null)
                        {
                            var addresses = await Dns.GetHostAddressesAsync(config.Host);
                            ep = new IPEndPoint(addresses[0], config.Port);
                        }

                        break;
                    default:
                        throw new ArgumentOutOfRangeException();
                }
            }

            var streamConf = new StreamSystemConfig()
            {
                UserName = config.Username,
                Password = config.Password,
                Endpoints = new List<EndPoint>() { ep },
                ClientProvidedName = "dotnet-stream-client-app",
                ConnectionPoolConfig = new ConnectionPoolConfig()
                {
                    ProducersPerConnection = config.ProducersPerConnection,
                    ConsumersPerConnection = config.ConsumersPerConnection,
                }
            };


            if (config.LoadBalancer)
            {
                var resolver = new AddressResolver(ep);
                streamConf = new StreamSystemConfig()
                {
                    AddressResolver = resolver,
                    UserName = config.Username,
                    Password = config.Password,
                    ClientProvidedName = "dotnet-stream-client-app",
                    ConnectionPoolConfig = new ConnectionPoolConfig()
                    {
                        ProducersPerConnection = config.ProducersPerConnection,
                        ConsumersPerConnection = config.ConsumersPerConnection,
                    },
                    Endpoints = new List<EndPoint>() { resolver.EndPoint }
                };
            }

            StreamSystem? system = null;
            var retryCount = 0;
            var maxRetries = 10;
            var retryDelay = TimeSpan.FromSeconds(5);

            while (system == null && !cancellationToken.IsCancellationRequested)
            {
                try
                {
                    await Console.Out.WriteLineAsync($"Attempting to connect to RabbitMQ (attempt {retryCount + 1}/{maxRetries})...");
                    system = await StreamSystem.Create(streamConf, ls);
                    await Console.Out.WriteLineAsync("Successfully connected to RabbitMQ");
                }
                catch (StreamSystemInitialisationException ex)
                {
                    retryCount++;
                    if (retryCount >= maxRetries)
                    {
                        await Console.Out.WriteLineAsync($"Failed to connect after {maxRetries} attempts. Exiting.");
                        throw;
                    }

                    await Console.Out.WriteLineAsync($"Connection failed: {ex.Message}. Retrying in {retryDelay.TotalSeconds} seconds...");
                    await Task.Delay(retryDelay, cancellationToken);
                }
            }

            if (system == null)
            {
                await Console.Out.WriteLineAsync("Failed to connect to RabbitMQ. Exiting.");
                return;
            }

            var streamsList = new List<string>();
            if (config.SuperStream)
            {
                if (config.StreamName != null) streamsList.Add(config.StreamName);
            }
            else
            {
                for (var i = 0; i < config.Streams; i++)
                {
                    streamsList.Add($"{config.StreamName}-{i}");
                }
            }

            var totalConfirmed = 0;
            var totalError = 0;
            var totalConsumed = 0;
            var totalSent = 0;
            var isRunning = true;

            _ = Task.Run(async () =>
            {
                while (isRunning && !cancellationToken.IsCancellationRequested)
                {
                    await Console.Out.WriteLineAsync(
                        $"When: {DateTime.Now}, " +
                        $"Tr {System.Diagnostics.Process.GetCurrentProcess().Threads.Count}, " +
                        $"Sent: {totalSent:#,##0.00}, " +
                        $"Conf: {totalConfirmed:#,##0.00}, " +
                        $"Error: {totalError:#,##0.00}, " +
                        $"Total: {(totalConfirmed + totalError):#,##0.00}, " +
                        $"Consumed all: {totalConsumed:#,##0.00}, " +
                        $"Consumed / Consumers : {totalConsumed / config.Consumers:#,##0.00}");
                    await Task.Delay(5000, cancellationToken);
                }
            }, cancellationToken);

            List<Consumer> consumersList = new();
            ConcurrentBag<Producer> producersBag = new();
            List<Task> producerTasks = new();

            if (config.SuperStream)
            {
                if (await system.SuperStreamExists(streamsList[0]))
                {
                    await system.DeleteSuperStream(streamsList[0]);
                }

                await system.CreateSuperStream(new PartitionsSuperStreamSpec(streamsList[0], config.Streams));
            }

            foreach (var stream in streamsList)
            {
                if (!config.SuperStream)
                {
                    if (await system.StreamExists(stream))
                    {
                        await system.DeleteStream(stream);
                    }

                    await system.CreateStream(new StreamSpec(stream) { MaxLengthBytes = 30_000_000_000, });
                    await Task.Delay(TimeSpan.FromSeconds(3));
                }

                for (var z = 0; z < config.Consumers; z++)
                {
                    var conf = new ConsumerConfig(system, stream)
                    {
                        OffsetSpec = new OffsetTypeLast(),
                        IsSuperStream = config.SuperStream,
                        IsSingleActiveConsumer = config.SuperStream,
                        Reference = "myApp", // needed for the Single Active Consumer or fot the store offset
                        // can help to identify the consumer on the logs and RabbitMQ Management
                        Identifier = $"my_consumer_{z}",
                        InitialCredits = 10,
                        MessageHandler = (source, consumer, ctx, _) =>
                        {
                            // if (totalConsumed % 10_000 == 0)
                            // {
                            //     // don't store the offset every time, it could be a performance issue
                            //     // store the offset every 1_000/5_000/10_000 messages
                            //     //    await consumer.StoreOffset(ctx.Offset);
                            // }
                            Interlocked.Increment(ref totalConsumed);
                            return Task.CompletedTask;
                        },
                    };

                    // This is the callback that will be called when the consumer status changes
                    // DON'T PUT ANY BLOCKING CODE HERE
                    conf.StatusChanged += (status) =>
                    {
                        var streamInfo = $"Stream: {status.Stream}";
                        if (status.Partitions is { Count: > 0 })
                        {
                            // the partitions are not null and not empty
                            // it is a super stream
                            var partitions = "[";
                            status.Partitions.ForEach(s => partitions += s + ",");
                            partitions = partitions.Remove(partitions.Length - 1) + "]";
                            streamInfo = $" Partitions: {partitions} of super stream: {status.Stream}";
                        }

                        lc.LogInformation(
                            "Consumer: {Id} - status changed from: {From} to: {To} reason: {Reason}  {Info}",
                            status.Identifier, status.From, status.To, status.Reason, streamInfo);

                        if (status.To == ReliableEntityStatus.Open)
                        {
                            Console.WriteLine($"Consumer {status.Identifier} connected to node");
                        }
                    };
                    consumersList.Add(
                        await Consumer.Create(conf, lc));
                }

                async Task MaybeSend(Producer producer, Message message, ManualResetEventSlim publishEvent)
                {
                    publishEvent.Wait();
                    await producer.Send(message);
                }

                // this example is meant to show how to use the producer and consumer
                // Create too many tasks for the producers and consumers is not a good idea
                for (var z = 0; z < config.Producers; z++)
                {
                    var z1 = z;
                    var producerTask = Task.Run(async () =>
                    {
                        // the list of unconfirmed messages in case of error or disconnection
                        // This example is only for the example, in a real scenario you should handle the unconfirmed messages
                        // since the list could grow event the publishEvent should avoid it.
                        var unconfirmedMessages = new ConcurrentBag<Message>();
                        // the event to wait for the producer to be ready to send
                        // in case of disconnection the event will be reset
                        var publishEvent = new ManualResetEventSlim(false);
                        var producerConfig = new ProducerConfig(system, stream)
                        {
                            Identifier = $"my_producer_{z1}",
                            SuperStreamConfig = new SuperStreamConfig()
                            {
                                Enabled = config.SuperStream, Routing = msg => msg.Properties.MessageId.ToString(),
                            },
                            ConfirmationHandler = confirmation =>
                            {
                                // Add the unconfirmed messages to the list in case of error
                                if (confirmation.Status != ConfirmationStatus.Confirmed)
                                {
                                    if (config.EnableResending)
                                    {
                                        confirmation.Messages.ForEach(m => { unconfirmedMessages.Add(m); });
                                    }

                                    Interlocked.Add(ref totalError, confirmation.Messages.Count);
                                    return Task.CompletedTask;
                                }

                                Interlocked.Add(ref totalConfirmed, confirmation.Messages.Count);
                                return Task.CompletedTask;
                            },
                        };

                        // Like the consumer don't put any blocking code here
                        producerConfig.StatusChanged += (status) =>
                        {
                            var streamInfo = $"Stream: {status.Stream}";
                            if (status.Partitions is { Count: > 0 })
                            {
                                // the partitions are not null and not empty
                                // it is a super stream
                                var partitions = "[";
                                status.Partitions.ForEach(s => partitions += s + ",");
                                partitions = partitions.Remove(partitions.Length - 1) + "]";
                                streamInfo = $" Partitions: {partitions} of super stream: {status.Stream}";
                            }


                            // just log the status change
                            lp.LogInformation(
                                "Producer: {Id} - status changed from: {From} to: {To} reason: {Reason}  {Info}",
                                status.Identifier, status.From, status.To, status.Reason, streamInfo);

                            // in case of disconnection the event will be reset
                            // in case of reconnection the event will be set so the producer can send messages
                            // It is important to use the ManualReset to avoid to send messages before the producer is ready
                            if (status.To == ReliableEntityStatus.Open)
                            {
                                Console.WriteLine($"Producer {status.Identifier} connected to node");
                                publishEvent.Set();
                            }
                            else
                            {
                                publishEvent.Reset();
                            }
                        };

                        var producer = await Producer.Create(producerConfig, lp);
                        producersBag.Add(producer);

                        for (var i = 0; i < config.MessagesPerProducer; i++)
                        {
                            if (cancellationToken.IsCancellationRequested)
                            {
                                break;
                            }

                            if (!unconfirmedMessages.IsEmpty)
                            {
                                // checks if there are unconfirmed messages and send them
                                var msgs = unconfirmedMessages.ToArray();
                                unconfirmedMessages.Clear();
                                foreach (var msg in msgs)
                                {
                                    await MaybeSend(producer, msg, publishEvent);
                                    Interlocked.Increment(ref totalSent);
                                }
                            }

                            var message = new Message(Encoding.Default.GetBytes("hello"))
                            {
                                Properties = new Properties() { MessageId = $"hello{i}" }
                            };

                            await MaybeSend(producer, message, publishEvent);

                            // You don't need this it is only for the example
                            await Task.Delay(config.DelayDuringSendMs);

                            Interlocked.Increment(ref totalSent);
                        }
                    });
                    producerTasks.Add(producerTask);
                }
            }

            try
            {
                await Task.WhenAll(producerTasks.Append(Task.Delay(Timeout.Infinite, cancellationToken)));
            }
            catch (OperationCanceledException)
            {
                await Console.Out.WriteLineAsync("Shutdown requested, stopping producers and consumers...");
                await Console.Out.FlushAsync();
                isRunning = false;

                await Console.Out.WriteLineAsync("Waiting for in-flight messages...");
                await Console.Out.FlushAsync();
                var timeout = TimeSpan.FromSeconds(10);
                var start = DateTime.UtcNow;
                while ((totalConfirmed + totalError) < totalSent && DateTime.UtcNow - start < timeout)
                {
                    await Task.Delay(100);
                }
                await Console.Out.WriteLineAsync($"Messages: Sent={totalSent}, Confirmed={totalConfirmed}, Error={totalError}");
                await Console.Out.FlushAsync();

                await Console.Out.WriteLineAsync("Closing producers...");
                await Console.Out.FlushAsync();
                foreach (var producer in producersBag)
                {
                    await producer.Close();
                }

                await Console.Out.WriteLineAsync("Closing consumers...");
                await Console.Out.FlushAsync();
                foreach (var consumer in consumersList)
                {
                    await consumer.Close();
                }

                await Console.Out.WriteLineAsync("Closing stream system...");
                await Console.Out.FlushAsync();
                if (system != null)
                {
                    await system.Close();
                }

                await Console.Out.WriteLineAsync("Cleanup complete");
                await Console.Out.FlushAsync();
            }
        }
    }

    public static async Task Main(string[] args)
    {
        Console.WriteLine("Application starting, registering signal handlers...");
        await Console.Out.FlushAsync();

        var config = new Config
        {
            Host = Environment.GetEnvironmentVariable("RABBITMQ_HOST") ?? "localhost",
            Port = int.TryParse(Environment.GetEnvironmentVariable("RABBITMQ_PORT"), out var port) ? port : 5552,
            Username = Environment.GetEnvironmentVariable("RABBITMQ_USERNAME") ?? "guest",
            Password = Environment.GetEnvironmentVariable("RABBITMQ_PASSWORD") ?? "guest"
        };

        var cts = new CancellationTokenSource();
        var shutdownComplete = new ManualResetEventSlim(false);

        AppDomain.CurrentDomain.ProcessExit += (sender, e) =>
        {
            Console.WriteLine("ProcessExit event received, initiating shutdown...");
            Console.Out.Flush();
            cts.Cancel();
            shutdownComplete.Wait(TimeSpan.FromSeconds(25));
        };

        PosixSignalRegistration.Create(PosixSignal.SIGTERM, context =>
        {
            Console.WriteLine("SIGTERM signal received, initiating shutdown...");
            Console.Out.Flush();
            context.Cancel = true;
            cts.Cancel();
        });

        PosixSignalRegistration.Create(PosixSignal.SIGINT, context =>
        {
            Console.WriteLine("SIGINT signal received, initiating shutdown...");
            Console.Out.Flush();
            context.Cancel = true;
            cts.Cancel();
        });

        await Start(config, cts.Token);
        shutdownComplete.Set();
    }
}
