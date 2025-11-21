package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/rabbitmq/rabbitmq-stream-go-client/pkg/amqp"
	"github.com/rabbitmq/rabbitmq-stream-go-client/pkg/stream"
)

type Config struct {
	Host                   string
	Port                   int
	Username               string
	Password               string
	StreamName             string
	Producers              int
	ProducersPerConnection int
	MessagesPerProducer    int
	Consumers              int
	ConsumersPerConnection int
	DelayDuringSendMs      int
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func getEnvInt(key string, defaultValue int) int {
	if value := os.Getenv(key); value != "" {
		if intValue, err := strconv.Atoi(value); err == nil {
			return intValue
		}
	}
	return defaultValue
}

func main() {
	config := Config{
		Host:                   getEnv("RABBITMQ_HOST", "localhost"),
		Port:                   getEnvInt("RABBITMQ_PORT", 5552),
		Username:               getEnv("RABBITMQ_USERNAME", "guest"),
		Password:               getEnv("RABBITMQ_PASSWORD", "guest"),
		StreamName:             "go-stream-client-app",
		Producers:              2,
		ProducersPerConnection: 1,
		MessagesPerProducer:    500_000,
		Consumers:              10,
		ConsumersPerConnection: 1,
		DelayDuringSendMs:      100,
	}

	fmt.Println("Go Stream Client Application")
	fmt.Printf("Connecting to %s:%d\n", config.Host, config.Port)

	// Setup signal handling with context
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	addressResolver := stream.AddressResolver{
		Host: config.Host,
		Port: config.Port,
	}

	env, err := stream.NewEnvironment(
		stream.NewEnvironmentOptions().
			SetHost(config.Host).
			SetPort(config.Port).
			SetUser(config.Username).
			SetPassword(config.Password).
			SetAddressResolver(addressResolver).
			SetMaxProducersPerClient(config.ProducersPerConnection).
			SetMaxConsumersPerClient(config.ConsumersPerConnection))
	if err != nil {
		fmt.Printf("Failed to create environment: %s\n", err)
		os.Exit(1)
	}
	defer env.Close()

	fmt.Printf("Creating stream: %s\n", config.StreamName)
	err = env.DeclareStream(config.StreamName,
		&stream.StreamOptions{
			MaxLengthBytes: stream.ByteCapacity{}.GB(5),
		})
	if err != nil {
		fmt.Printf("Failed to declare stream: %s\n", err)
		os.Exit(1)
	}

	// Wait for stream to be available across cluster
	time.Sleep(3 * time.Second)

	var producerWg sync.WaitGroup
	var consumerWg sync.WaitGroup
	var totalSent atomic.Int64
	var totalConfirmed atomic.Int64
	var totalReceived atomic.Int64
	var producers []*stream.Producer
	var consumers []*stream.Consumer
	var producersMutex sync.Mutex
	var consumersMutex sync.Mutex

	fmt.Printf("Starting %d producers (%d messages each)\n", config.Producers, config.MessagesPerProducer)
	startTime := time.Now()

	// Periodic statistics reporting
	stopStats := make(chan bool)
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				sent := totalSent.Load()
				confirmed := totalConfirmed.Load()
				consumed := totalReceived.Load()
				elapsed := time.Since(startTime)
				fmt.Printf("[%s] Sent: %d, Confirmed: %d, Consumed: %d, Elapsed: %v\n",
					time.Now().Format("15:04:05"), sent, confirmed, consumed, elapsed.Round(time.Second))
			case <-stopStats:
				return
			}
		}
	}()

	for i := 0; i < config.Producers; i++ {
		producerWg.Add(1)
		go func(producerID int) {
			defer producerWg.Done()

			producer, err := env.NewProducer(config.StreamName,
				stream.NewProducerOptions().
					SetClientProvidedName(fmt.Sprintf("go-producer-%d", producerID)))
			if err != nil {
				fmt.Printf("Failed to create producer %d: %s\n", producerID, err)
				return
			}

			producersMutex.Lock()
			producers = append(producers, producer)
			producersMutex.Unlock()

			chConfirm := producer.NotifyPublishConfirmation()
			go func() {
				for confirmed := range chConfirm {
					for _, msg := range confirmed {
						if msg.IsConfirmed() {
							totalConfirmed.Add(1)
						}
					}
				}
			}()

			for j := 0; j < config.MessagesPerProducer; j++ {
				// Check if context is cancelled (Ctrl+C pressed)
				select {
				case <-ctx.Done():
					return
				default:
				}

				message := fmt.Sprintf("producer-%d-message-%d", producerID, j)
				err := producer.Send(amqp.NewMessage([]byte(message)))
				if err != nil {
					// Only log error if not shutting down
					select {
					case <-ctx.Done():
						return
					default:
						fmt.Printf("Producer %d failed to send message %d: %s\n", producerID, j, err)
					}
					continue
				}
				totalSent.Add(1)

				if config.DelayDuringSendMs > 0 && j > 0 && j%1000 == 0 {
					time.Sleep(time.Duration(config.DelayDuringSendMs) * time.Millisecond)
				}
			}
		}(i)
	}

	fmt.Printf("Starting %d consumers\n", config.Consumers)

	for i := 0; i < config.Consumers; i++ {
		consumerWg.Add(1)
		go func(consumerID int) {
			defer consumerWg.Done()

			handleMessages := func(consumerContext stream.ConsumerContext, message *amqp.Message) {
				totalReceived.Add(1)
			}

			consumer, err := env.NewConsumer(
				config.StreamName,
				handleMessages,
				stream.NewConsumerOptions().
					SetClientProvidedName(fmt.Sprintf("go-consumer-%d", consumerID)).
					SetConsumerName(fmt.Sprintf("go-consumer-%d", consumerID)).
					SetOffset(stream.OffsetSpecification{}.First()))
			if err != nil {
				fmt.Printf("Failed to create consumer %d: %s\n", consumerID, err)
				return
			}

			consumersMutex.Lock()
			consumers = append(consumers, consumer)
			consumersMutex.Unlock()

			channelClose := consumer.NotifyClose()
			<-channelClose
		}(i)
	}

	// Wait for signal or producers to finish
	go func() {
		producerWg.Wait()
		fmt.Println("\nAll producers finished, initiating shutdown...")
		sigChan <- syscall.SIGTERM
	}()

	<-sigChan
	cancel() // Cancel context to stop producers gracefully
	fmt.Println("Shutdown signal received, stopping...")

	fmt.Printf("\nProduction complete:\n")
	fmt.Printf("  Messages sent: %d\n", totalSent.Load())
	fmt.Printf("  Messages confirmed: %d\n", totalConfirmed.Load())

	// Close all producers
	fmt.Println("Closing producers...")
	producersMutex.Lock()
	for _, producer := range producers {
		producer.Close()
	}
	producersMutex.Unlock()

	// Close all consumers
	fmt.Println("Closing consumers...")
	consumersMutex.Lock()
	for _, consumer := range consumers {
		consumer.Close()
	}
	consumersMutex.Unlock()

	consumerWg.Wait()

	duration := time.Since(startTime)

	// Stop statistics reporting before final output
	stopStats <- true

	fmt.Printf("\nAll operations complete:\n")
	fmt.Printf("  Total duration: %v\n", duration)
	fmt.Printf("  Messages received: %d\n", totalReceived.Load())
}
