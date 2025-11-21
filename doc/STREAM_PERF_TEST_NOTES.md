# rabbitmq-stream-perf-test Topology Intelligence

## Overview
The `rabbitmq-stream-perf-test` application is a Java-based performance testing tool for RabbitMQ Streams. It uses the RabbitMQ Stream Java client library and therefore has access to the same topology intelligence features documented in `JAVA_NOTES.md`.

## Key Finding
**The stream-perf-test application requires explicit configuration to force consumers onto replica nodes. Without the `--force-replica-for-consumers` flag, consumers CAN and WILL connect to leader nodes.**

## Configuration Flags

### `--force-replica-for-consumers`
- **Location**: `com.rabbitmq.stream.perf.StreamPerfTest` (line 572-580)
- **Default Value**: `false`
- **Purpose**: Controls whether consumers MUST connect to replica nodes only

```java
@CommandLine.Option(
    names = {"--force-replica-for-consumers"},
    description = "force the connection to a replica for consumers",
    arity = "0..1",
    fallbackValue = "true",
    defaultValue = "false")
void setForceReplicaForConsumers(String input) throws Exception {
  this.forceReplicaForConsumers = Converters.BOOLEAN_TYPE_CONVERTER.convert(input);
}

volatile boolean forceReplicaForConsumers;
```

**Usage**:
```bash
# Force consumers to replicas only
--force-replica-for-consumers

# Explicitly enable (same as above)
--force-replica-for-consumers true

# Explicitly disable (default behavior)
--force-replica-for-consumers false
```

### `--load-balancer`
- **Location**: `com.rabbitmq.stream.perf.StreamPerfTest` (line 354-364)
- **Default Value**: `false`
- **Purpose**: Configures the application to work with a load balancer

```java
@CommandLine.Option(
    names = {"--load-balancer", "-lb"},
    description = "assume URIs point to a load balancer",
    arity = "0..1",
    fallbackValue = "true",
    defaultValue = "false")
void setLoadBalancer(String input) throws Exception {
  this.loadBalancer = Converters.BOOLEAN_TYPE_CONVERTER.convert(input);
}

volatile boolean loadBalancer;
```

**What it does** (lines 980-1003):
- Parses URIs to extract addresses
- Creates an address resolver that round-robins through the addresses
- Allows the client to work through a load balancer endpoint

## How It Works

### Environment Builder Configuration
The `forceReplicaForConsumers` flag is passed to the Environment builder (line 1053):

```java
Environment.builder()
    .addressResolver(addrResolver)
    .maxProducersByConnection(this.producersByConnection)
    .maxTrackingConsumersByConnection(this.trackingConsumersByConnection)
    .maxConsumersByConnection(this.consumersByConnection)
    .rpcTimeout(Duration.ofSeconds(this.rpcTimeout))
    .requestedMaxFrameSize((int) this.requestedMaxFrameSize.toBytes())
    .forceReplicaForConsumers(this.forceReplicaForConsumers)  // <-- HERE
    .requestedHeartbeat(Duration.ofSeconds(this.heartbeat))
    .recoveryBackOffDelayPolicy(this.recoveryBackOffDelayPolicy)
    .build();
```

This directly uses the same mechanism documented in `JAVA_NOTES.md`:
- Queries stream metadata to get leader and replica information
- Uses `ConsumersCoordinator.findCandidateNodes()` to build candidate list
- When `forceReplicaForConsumers = false`: adds leader to candidate list
- When `forceReplicaForConsumers = true`: excludes leader from candidate list

## Observed Behavior

### Without `--force-replica-for-consumers` (Default)

**Test Environment**:
- 3-node RabbitMQ cluster (rmq0, rmq1, rmq2)
- HAProxy load balancer with round-robin distribution
- Stream: `stream` with leader on `rabbit@rmq2`
- 5 producers, 5 consumers
- Command: `--load-balancer` (without `--force-replica-for-consumers`)

**Results**:
- **Consumers consistently found on leader node** (`rabbit@rmq2`)
- This is expected behavior with `forceReplicaForConsumers = false`

**Why this happens**:
1. Candidate list includes: [replica1, replica2, leader]
2. Random selection from 3 candidates gives 33% chance of selecting leader
3. With 5 consumers and random selection, at least one consumer landing on leader is highly probable
4. Over multiple runs, consumers will be distributed across all nodes including the leader

### With `--force-replica-for-consumers`

**Expected Results**:
- **No consumers on leader node**
- All consumers distributed across replica nodes only
- Exception thrown if only leader is available (no replicas)

**Why this works**:
1. Candidate list includes: [replica1, replica2] (leader excluded)
2. Random selection only chooses from replicas
3. Consumers guaranteed to avoid leader node

## Makefile Configuration

### Original Command (Problematic)
```makefile
run-stream-perf-test:
	docker run --rm --pull always --network rabbitnet \
	  pivotalrabbitmq/stream-perf-test:latest \
	  --uris rabbitmq-stream://haproxy:5552 \
	  --producers 5 \
	  --consumers 5 \
	  --rate 1000 \
	  --delete-streams \
	  --max-age PT30S \
	  --load-balancer
```

**Issue**: Missing `--force-replica-for-consumers` flag, allowing consumers on leader.

### Updated Command (Fixed)
```makefile
run-stream-perf-test:
	docker run --rm --pull always --network rabbitnet \
	  pivotalrabbitmq/stream-perf-test:latest \
	  --uris rabbitmq-stream://haproxy:5552 \
	  --producers 5 \
	  --consumers 5 \
	  --rate 1000 \
	  --delete-streams \
	  --max-age PT30S \
	  --load-balancer \
	  --force-replica-for-consumers
```

**Fix**: Added `--force-replica-for-consumers` to enforce replica-only consumer connections.

## Code References

### Key Files

1. **com.rabbitmq.stream.perf.StreamPerfTest**
   - `forceReplicaForConsumers` field (line 580)
   - `setForceReplicaForConsumers()` method (line 576)
   - `loadBalancer` field (line 364)
   - `setLoadBalancer()` method (line 360)
   - Environment builder configuration (line 1053)
   - Load balancer address resolver setup (lines 980-1003)

2. **com.rabbitmq.stream.perf.PicoCliTest**
   - Tests for `--force-replica-for-consumers` flag behavior
   - Validates default value is `false`
   - Validates flag can be set to `true` or `false`

## Comparison with Custom Applications

### stream-perf-test
- **Requires explicit flag** to force replica-only consumers
- **Default behavior** (`false`) allows consumers on leader
- Provides flexibility for testing different scenarios

### java-stream-client-app
- **Uses default Java client behavior** (`forceReplicaForConsumers = false`)
- **Statistically avoids leader** due to random selection from larger candidate pool
- Now updated to use `forceReplicaForConsumers(true)` for strict enforcement

### dotnet-stream-client-app
- **Uses .NET client default behavior** (no configuration flag)
- **Guarantees consumers avoid leader** when replicas exist
- Leader only used as fallback when no replicas available

## Summary

The `rabbitmq-stream-perf-test` application:

1. **Uses the RabbitMQ Stream Java client** with all its topology intelligence
2. **Exposes configuration flags** for controlling consumer placement behavior
3. **Defaults to allowing consumers on leader** (`forceReplicaForConsumers = false`)
4. **Requires `--force-replica-for-consumers` flag** to enforce replica-only consumer connections
5. **Works with load balancers** via the `--load-balancer` flag

For optimal stream performance in load-balanced environments, **always use both flags together**:
```bash
--load-balancer --force-replica-for-consumers
```

This ensures:
- Proper load balancer address resolution
- Consumers connect only to replica nodes
- Leader node is reserved for producers and stream management
