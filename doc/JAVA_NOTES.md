# RabbitMQ Stream Java Client Topology Intelligence

## Overview
The RabbitMQ Java Stream client has built-in intelligence to optimize connection placement for producers and consumers, even when connecting through a load balancer. This intelligence is based on querying stream topology metadata from RabbitMQ and making routing decisions accordingly.

## Key Finding
**By default (`forceReplicaForConsumers = false`), consumers can connect to ANY node (leader or replicas), but the selection algorithm PREFERS replicas over the leader.**

## Configuration Flag

### `forceReplicaForConsumers`
- **Location**: `com.rabbitmq.stream.impl.StreamEnvironmentBuilder`
- **Default Value**: `false` (line 80)
- **Purpose**: Controls whether consumers MUST connect to replica nodes only

```java
private boolean forceReplicaForConsumers = false;
private boolean forceLeaderForProducers = true;
```

**When `false` (default)**:
- Consumers prefer replicas but can fall back to leader
- Leader is added to candidate list if replicas exist

**When `true`**:
- Consumers MUST connect to replicas only
- Throws exception if only leader is available

## How It Works

### 1. Metadata Query Protocol

The client queries RabbitMQ for stream topology information using the Stream Protocol's metadata command.

**Command**: `COMMAND_METADATA` (Command Code: 15)
- **Constant Location**: `com.rabbitmq.stream.Constants` (line 62)
- **Method**: `Client.metadata(String... streams)`
- **Location**: `com.rabbitmq.stream.impl.Client` (line ~964)

**Request Structure**:
```java
int length = 2 + 2 + 4 + arraySize(streams); // API code, version, correlation ID, array size
ByteBuf bb = allocate(length + 4);
bb.writeInt(length);
bb.writeShort(encodeRequestCode(COMMAND_METADATA));
bb.writeShort(VERSION_1);
bb.writeInt(correlationId);
writeArray(bb, streams);
```

### 2. Metadata Response

RabbitMQ responds with complete cluster topology information.

**Response Handler**: `MetadataFrameHandler`
- **Location**: `com.rabbitmq.stream.impl.ServerFrameHandler` (line 1015)
- **Registered**: Line 132 in ServerFrameHandler

**Response Parsing** (lines 1018-1063):
```java
Map<Short, Broker> brokers = new HashMap<>();
int brokersCount = message.readInt();
for (int i = 0; i < brokersCount; i++) {
    short brokerReference = message.readShort();
    String host = readString(message);
    int port = message.readInt();
    brokers.put(brokerReference, new Broker(host, port));
}

int streamsCount = message.readInt();
Map<String, StreamMetadata> results = new LinkedHashMap<>(streamsCount);
for (int i = 0; i < streamsCount; i++) {
    String stream = readString(message);
    short responseCode = message.readShort();
    short leaderReference = message.readShort();
    int replicasCount = message.readInt();
    
    List<Broker> replicas = new ArrayList<>(replicasCount);
    for (int j = 0; j < replicasCount; j++) {
        short replicaReference = message.readShort();
        replicas.add(brokers.get(replicaReference));
    }
    
    StreamMetadata streamMetadata =
        new StreamMetadata(stream, responseCode, brokers.get(leaderReference), replicas);
    results.put(stream, streamMetadata);
}
```

**Data Structure**:
```java
public static class StreamMetadata {
    private final String stream;
    private final short responseCode;
    private final Broker leader;
    private final List<Broker> replicas;
}

public static class Broker {
    private final String host;
    private final int port;
}
```

### 3. Consumer Routing Logic

**Method**: `findCandidateNodes(String stream, boolean forceReplica)`
- **Location**: `com.rabbitmq.stream.impl.ConsumersCoordinator` (line 263)
- **Called by**: Consumer subscription process

**Algorithm** (lines 263-318):
```java
List<BrokerWrapper> findCandidateNodes(String stream, boolean forceReplica) {
    LOGGER.debug(
        "Candidate lookup to consumer from '{}', forcing replica? {}", stream, forceReplica);
    
    // Query metadata
    Map<String, Client.StreamMetadata> metadata =
        this.environment.locatorOperation(
            namedFunction(c -> c.metadata(stream), "Candidate lookup to consume from '%s'", stream));
    
    Client.StreamMetadata streamMetadata = metadata.get(stream);
    Broker leader = streamMetadata.getLeader();
    List<Broker> replicas = streamMetadata.getReplicas();
    
    List<BrokerWrapper> brokers;
    if (replicas == null || replicas.isEmpty()) {
        // NO REPLICAS AVAILABLE
        if (forceReplica) {
            // Strict mode: throw exception
            throw new IllegalStateException(
                format("Only the leader node is available for consuming from %s and "
                    + "consuming from leader has been deactivated for this consumer", stream));
        } else {
            // Default mode: use leader as fallback
            brokers = Collections.singletonList(new BrokerWrapper(leader, true));
            LOGGER.debug("Only leader node {} for consuming from {}", leader, stream);
        }
    } else {
        // REPLICAS AVAILABLE
        LOGGER.debug("Replicas for consuming from {}: {}", stream, replicas);
        
        // Add all replicas to candidate list
        brokers = replicas.stream()
            .map(b -> new BrokerWrapper(b, false))
            .collect(Collectors.toCollection(ArrayList::new));
        
        // CRITICAL LINE: Add leader ONLY if forceReplica is false
        if (!forceReplica && leader != null) {
            brokers.add(new BrokerWrapper(leader, true));
        }
    }
    
    LOGGER.debug("Candidates to consume from {}: {}", stream, brokers);
    return brokers;
}
```

**Key Logic**:
1. Query metadata to get leader and replicas
2. **If no replicas exist**:
   - `forceReplica = true`: Throw exception
   - `forceReplica = false`: Use leader as only option
3. **If replicas exist**:
   - Add ALL replicas to candidate list
   - **Add leader ONLY if `forceReplica = false`** (line 310)
4. Return candidate list

**Broker Selection**:
After getting candidates, a broker is picked using `brokerPicker` function:
- **Location**: `Utils.brokerPicker()` 
- **Behavior**: Randomly selects from the candidate list

**Result with default settings (`forceReplica = false`)**:
- Candidate list contains: [replica1, replica2, ..., replicaN, leader]
- Random selection gives replicas higher probability (N replicas vs 1 leader)
- Consumers will statistically prefer replicas but CAN connect to leader

### 4. Producer Routing Logic

**Method**: `findLeaderNode(String stream)`
- **Location**: `com.rabbitmq.stream.impl.ProducersCoordinator`
- **Behavior**: Always returns the leader node

Producers **always** connect to the leader node, regardless of configuration.

### 5. Load Balancer Interaction

Similar to the .NET client, the Java client works through load balancers by:

1. Initial connection goes through load balancer
2. Client queries metadata through that connection
3. Client receives actual broker addresses (rmq0, rmq1, rmq2)
4. Client attempts to connect to the appropriate broker from the candidate list
5. If using `AddressResolver`, validates that connection reached the intended node
6. Retries through load balancer until reaching the correct node

## Observed Behavior

### Test Environment
- 3-node RabbitMQ cluster (rmq0, rmq1, rmq2)
- HAProxy load balancer with round-robin distribution
- Stream: `java-stream-client-app` with leader on `rabbit@rmq0`
- 10 consumers, 2 producers
- Default configuration (`forceReplicaForConsumers = false`)

### Results
**Consumers**:
- All 10 consumers connected to replica nodes (rmq1 and/or rmq2)
- **0 consumers on `rabbit@rmq0` (leader)**

**Producers**:
- 2 producers on `rabbit@rmq0` (leader)

**Interpretation**:
Even though `forceReplicaForConsumers = false` allows consumers to connect to the leader, the random selection from a candidate list containing [replica1, replica2, leader] statistically favors replicas. With multiple replicas available, the probability of selecting the leader is low (1 out of 3 in a 3-node cluster).

## Code References

### Key Files

1. **com.rabbitmq.stream.impl.StreamEnvironmentBuilder**
   - `forceReplicaForConsumers` field (line 80)
   - `forceReplicaForConsumers()` method (line ~350)

2. **com.rabbitmq.stream.impl.ConsumersCoordinator**
   - `forceReplica` field (line 108)
   - Constructor accepting `forceReplica` parameter (line 116)
   - `findCandidateNodes()` method (line 263)
   - Critical logic at line 310: `if (!forceReplica && leader != null)`

3. **com.rabbitmq.stream.impl.Client**
   - `metadata()` method (line ~964)
   - `StreamMetadata` class (line ~2400)
   - `Broker` class (line ~2425)

4. **com.rabbitmq.stream.impl.ServerFrameHandler**
   - `MetadataFrameHandler` class (line 1015)
   - Metadata response parsing (lines 1018-1063)
   - Handler registration (line 132)

5. **com.rabbitmq.stream.Constants**
   - `COMMAND_METADATA = 15` (line 62)

6. **com.rabbitmq.stream.EnvironmentBuilder**
   - `forceReplicaForConsumers()` interface method

## Comparison with .NET Client

### Similarities
1. Both query metadata using Stream Protocol command 15
2. Both receive leader and replica information
3. Both make intelligent routing decisions based on topology
4. Both work through load balancers with retry logic

### Differences

**Java Client**:
- Has explicit `forceReplicaForConsumers` configuration flag
- Default behavior (`false`) adds leader to candidate list
- Uses random selection from candidates (statistical preference for replicas)
- Can connect to leader even with replicas available (low probability)

**.NET Client**:
- No configuration flag for consumer routing
- **Never adds leader to candidate list when replicas exist**
- Only uses leader as fallback when NO replicas available
- Guarantees consumers avoid leader when replicas exist

**Practical Impact**:
Both clients achieve the same goal of keeping consumers off the leader node in normal circumstances, but the .NET client provides a stronger guarantee while the Java client offers more flexibility through configuration.

## Summary

The RabbitMQ Java Stream client demonstrates sophisticated topology awareness:

1. **Queries cluster topology** via Stream Protocol metadata command (15)
2. **Receives complete cluster information** including leader and replica locations
3. **Makes intelligent routing decisions**:
   - Producers → Leader node (always)
   - Consumers → Prefer replicas (default), with configurable strictness
4. **Works through load balancers** by retrying connections until reaching the intended node
5. **Optimizes for stream performance** by statistically keeping consumers off the leader node

The `forceReplicaForConsumers` flag provides flexibility:
- `false` (default): Consumers prefer replicas but can use leader (statistical optimization)
- `true`: Consumers must use replicas only (strict enforcement)

This intelligence is **built into the client library** and works automatically with default settings to achieve optimal connection distribution.
