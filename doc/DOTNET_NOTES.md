# RabbitMQ.Stream.Client Topology Intelligence

## Overview
The RabbitMQ .NET Stream client has built-in intelligence to optimize connection placement for producers and consumers, even when connecting through a load balancer. This intelligence is based on querying stream topology metadata from RabbitMQ and making routing decisions accordingly.

## Key Finding
**Consumers preferentially connect to replica nodes, avoiding the stream leader, even when all connections go through a load balancer.**

## How It Works

### 1. Metadata Query Protocol

The client queries RabbitMQ for stream topology information using the Stream Protocol's metadata command.

**Command**: `MetaDataQuery` (Command Key: 15)
- **Location**: `RabbitMQ.Stream.Client/MetaData.cs`
- **Method**: `Client.QueryMetadata(string[] streams)`
- **Purpose**: Request topology information for specified streams

**Request Structure**:
```csharp
public readonly struct MetaDataQuery : ICommand
{
    public const ushort Key = 15;
    private readonly uint correlationId;
    private readonly IEnumerable<string> streams;
}
```

### 2. Metadata Response

RabbitMQ responds with complete cluster topology information.

**Response**: `MetaDataResponse` (Command Key: 15)
- **Location**: `RabbitMQ.Stream.Client/MetaData.cs`
- **Contains**:
  - List of all brokers (nodes) in the cluster with host:port
  - For each stream:
    - Leader broker reference
    - List of replica broker references

**Response Parsing** (lines 125-145 in MetaData.cs):
```csharp
offset += WireFormatting.ReadInt16(frame.Slice(offset), out var leaderRef);
offset += WireFormatting.ReadUInt32(frame.Slice(offset), out var numReplicas);
var replicaRefs = new short[numReplicas];
for (var j = 0; j < numReplicas; j++)
{
    offset += WireFormatting.ReadInt16(frame.Slice(offset), out replicaRefs[j]);
}

var replicas = replicaRefs.Select(r => brokers[r]).ToList();
var leader = brokers.TryGetValue(leaderRef, out var value) ? value : default;
streamInfos.Add(stream, new StreamInfo(stream, (ResponseCode)code, leader, replicas));
```

**Data Structure**:
```csharp
public readonly struct StreamInfo
{
    public string Stream { get; }
    public ResponseCode ResponseCode { get; }
    public Broker Leader { get; }
    public IList<Broker> Replicas { get; }
}

public readonly struct Broker
{
    public string Host { get; }
    public uint Port { get; }
}
```

### 3. Consumer Routing Logic

**Method**: `LookupLeaderOrRandomReplicasConnection`
- **Location**: `RabbitMQ.Stream.Client/RoutingClient.cs` (lines 193-207)
- **Called by**: `RawConsumer.Create()`

**Algorithm**:
```csharp
public static async Task<IClient> LookupLeaderOrRandomReplicasConnection(
    ClientParameters clientParameters,
    StreamInfo metaDataInfo, 
    ConnectionsPool pool, 
    ILogger logger = null)
{
    var brokers = new List<Broker>();
    
    // Only add leader if there are NO replicas
    if (metaDataInfo.Replicas is { Count: <= 0 })
    {
        brokers.Add(metaDataInfo.Leader);
    }

    // Add all replicas
    brokers.AddRange(metaDataInfo.Replicas);

    // Randomize the order
    var br = brokers.OrderBy(x => Random.Shared.Next()).ToList();

    // Try to connect to brokers in random order
    foreach (var broker in br)
    {
        try
        {
            // Attempt connection...
        }
        catch
        {
            // Try next broker
        }
    }
}
```

**Key Logic**:
1. Create empty broker list
2. **Only add leader if replicas list is empty** - this is the critical line
3. Add all replicas to the list
4. Randomize the order using `Random.Shared.Next()`
5. Attempt connections in randomized order
6. Return first successful connection

**Result**: Consumers will connect to a random replica node, only falling back to the leader if no replicas exist.

### 4. Producer Routing Logic

**Method**: `LookupLeaderConnection`
- **Location**: `RabbitMQ.Stream.Client/RoutingClient.cs` (lines 172-186)
- **Called by**: `RawProducer.Create()`

**Algorithm**:
```csharp
public static async Task<IClient> LookupLeaderConnection(
    ClientParameters clientParameters,
    StreamInfo metaDataInfo, 
    ConnectionsPool pool, 
    ILogger logger = null)
{
    return await pool.GetOrCreateClient(metaDataInfo.Leader.ToString(),
        async () =>
            await LookupConnection(mergedClientParameters, metaDataInfo.Leader,
                    MaxAttempts(metaDataInfo), logger)
                .ConfigureAwait(false)).ConfigureAwait(false);
}
```

**Key Logic**: Producers **always** connect to the leader node (`metaDataInfo.Leader`).

### 5. Load Balancer Interaction

When `AddressResolver` is configured (load balancer mode):

**Location**: `RabbitMQ.Stream.Client/RoutingClient.cs` (lines 45-100)

**Process**:
1. Initial connection goes through load balancer
2. Client queries metadata through that connection
3. Client receives actual broker addresses (rmq0, rmq1, rmq2)
4. Client attempts to connect directly to the appropriate broker
5. If `AddressResolver` is enabled, it validates that `advertised_host` and `advertised_port` match the target broker
6. If they don't match, client reconnects through load balancer until it reaches the correct node

**Code**:
```csharp
var advertisedHost = GetPropertyValue(client.ConnectionProperties, "advertised_host");
var advertisedPort = GetPropertyValue(client.ConnectionProperties, "advertised_port");

var attemptNo = 0;
while (broker.Host != advertisedHost || broker.Port != uint.Parse(advertisedPort))
{
    attemptNo++;
    await client.Close("advertised_host or advertised_port doesn't match").ConfigureAwait(false);
    
    // Reconnect through load balancer
    client = await routing.CreateClient(
        clientParameters with { Endpoint = endPoint, ClientProvidedName = clientParameters.ClientProvidedName }, 
        broker, logger).ConfigureAwait(false);
    
    // Check again...
}
```

This retry mechanism ensures the client eventually connects to the intended node, even when the load balancer uses round-robin distribution.

## Observed Behavior

### Test Environment
- 3-node RabbitMQ cluster (rmq0, rmq1, rmq2)
- HAProxy load balancer with round-robin distribution
- Stream: `dotnet-stream-client-app-0` with leader on `rabbit@rmq0`
- 10 consumers, 2 producers

### Results
**Consumers**:
- 6 consumers on `rabbit@rmq1` (replica)
- 4 consumers on `rabbit@rmq2` (replica)
- **0 consumers on `rabbit@rmq0` (leader)**

**Producers**:
- 2 producers on `rabbit@rmq0` (leader)

**Connections on Leader Node (rmq0)**:
- 1 locator connection (`dotnet-stream-client-app`)
- 2 producer connections (`dotnet-stream-producer`)
- 0 consumer connections

## Code References

### Key Files
1. **RabbitMQ.Stream.Client/MetaData.cs**
   - `MetaDataQuery` struct (line ~12)
   - `MetaDataResponse` struct (line ~88)
   - `StreamInfo` struct (line ~63)
   - Response parsing logic (line ~125)

2. **RabbitMQ.Stream.Client/RoutingClient.cs**
   - `LookupLeaderOrRandomReplicasConnection()` (line ~193)
   - `LookupLeaderConnection()` (line ~172)
   - Load balancer retry logic (line ~45)

3. **RabbitMQ.Stream.Client/RawConsumer.cs**
   - `Create()` method calls `LookupLeaderOrRandomReplicasConnection()` (line ~77)

4. **RabbitMQ.Stream.Client/RawProducer.cs**
   - `Create()` method calls `LookupLeaderConnection()`

5. **RabbitMQ.Stream.Client/Client.cs**
   - `QueryMetadata()` method (line ~350)

## Summary

The RabbitMQ .NET Stream client demonstrates sophisticated topology awareness:

1. **Queries cluster topology** via Stream Protocol metadata command
2. **Receives complete cluster information** including leader and replica locations
3. **Makes intelligent routing decisions**:
   - Producers → Leader node
   - Consumers → Random replica node (leader only as fallback)
4. **Works through load balancers** by retrying connections until reaching the intended node
5. **Optimizes for stream performance** by keeping consumers off the leader node

This intelligence is **built into the client library** and requires no application-level configuration beyond enabling the `AddressResolver` for load balancer scenarios.
