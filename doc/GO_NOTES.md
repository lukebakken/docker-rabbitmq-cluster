# Go Stream Client - Consumer Placement Strategy

## Source Code Location
- Repository: https://github.com/rabbitmq/rabbitmq-stream-go-client
- File: `pkg/stream/client.go`
- Method: `BrokerForConsumer` (line 725)

## Consumer Placement Algorithm

### Key Method: `BrokerForConsumer`
```go
func (c *Client) BrokerForConsumer(stream string) (*Broker, error) {
    streamsMetadata := c.metaData(stream)
    streamMetadata := streamsMetadata.Get(stream)
    
    // Build candidate list: leader + all replicas
    brokers := make([]*Broker, 0, 1+len(streamMetadata.Replicas))
    brokers = append(brokers, streamMetadata.Leader)
    for idx, replica := range streamMetadata.Replicas {
        if replica == nil {
            logs.LogWarn("Stream %s replica not ready: %d", stream, idx)
            continue
        }
        brokers = append(brokers, replica)
    }
    
    // Random selection from ALL candidates (leader + replicas)
    r := rand.New(rand.NewSource(time.Now().UnixNano()))
    n := r.Intn(len(brokers))
    return brokers[n], nil
}
```

## Behavior Analysis

### Candidate Selection
1. **Always includes leader** - `brokers = append(brokers, streamMetadata.Leader)`
2. **Adds all available replicas** - iterates through `streamMetadata.Replicas`
3. **Random selection** - uses `rand.Intn(len(brokers))` to pick from all candidates

### Probability Distribution
For a stream with 1 leader + 2 replicas:
- **Leader probability**: 1/3 (33.3%)
- **Each replica probability**: 1/3 (33.3%)

### Comparison with Other Clients

| Client | Leader Included? | Replica Preference | Configuration Option |
|--------|------------------|-------------------|---------------------|
| **.NET** | Only if no replicas | Guaranteed replica avoidance | None (automatic) |
| **Java** | Depends on flag | Statistical preference | `forceReplicaForConsumers` |
| **Go** | Always | Equal probability | **None available** |

## Critical Difference

**The Go client has NO mechanism to prefer or enforce replica-only consumers.**

- No configuration flag equivalent to Java's `forceReplicaForConsumers`
- No automatic replica preference like .NET's `LookupLeaderOrRandomReplicasConnection`
- Leader is always included in candidate pool with equal probability

## Metadata Query Protocol

Like .NET and Java clients, the Go client queries stream metadata to get topology:
- Uses same Stream Protocol metadata command (15)
- Receives leader and replica broker references
- Parses `streamMetadata.Leader` and `streamMetadata.Replicas`

## Implications

1. **Load distribution**: Consumers will be evenly distributed across leader + replicas
2. **Leader load**: Leader receives ~33% of consumer connections (with 2 replicas)
3. **No avoidance option**: Cannot configure consumers to avoid leader node
4. **Predictable behavior**: Simple random selection, no complex logic

## Recommendation

If replica-only consumer placement is required with the Go client, it would need:
- Custom implementation or wrapper
- Feature request to rabbitmq-stream-go-client project
- Or use .NET/Java clients which support this capability
