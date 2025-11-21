# Go Stream Client - Consumer Placement Strategy

## Source Code Location
- Repository: https://github.com/rabbitmq/rabbitmq-stream-go-client
- Fork with fixes: https://github.com/lukebakken/rmq-rabbitmq-stream-go-client
- Branch: `lukebakken/consumer-replica-preference`
- Files modified:
  - `pkg/stream/client.go` - Consumer broker selection and DNS timeout fix
  - `pkg/stream/environment.go` - Consumer connection validation

## Consumer Placement Algorithm (Updated Implementation)

### Key Method: `BrokerForConsumer`
```go
func (c *Client) BrokerForConsumer(stream string) (*Broker, error) {
    streamsMetadata := c.metaData(stream)
    streamMetadata := streamsMetadata.Get(stream)
    
    brokers := make([]*Broker, 0, 1+len(streamMetadata.Replicas))
    
    // Count available replicas
    availableReplicas := 0
    for _, replica := range streamMetadata.Replicas {
        if replica != nil {
            availableReplicas++
        }
    }
    
    // Only add leader if no replicas are available
    if availableReplicas == 0 {
        streamMetadata.Leader.advPort = streamMetadata.Leader.Port
        streamMetadata.Leader.advHost = streamMetadata.Leader.Host
        brokers = append(brokers, streamMetadata.Leader)
    }
    
    // Add all available replicas
    for idx, replica := range streamMetadata.Replicas {
        if replica == nil {
            logs.LogWarn("Stream %s replica not ready: %d", stream, idx)
            continue
        }
        replica.advPort = replica.Port
        replica.advHost = replica.Host
        brokers = append(brokers, replica)
    }
    
    // Random selection from available brokers
    r := rand.New(rand.NewSource(time.Now().UnixNano()))
    n := r.Intn(len(brokers))
    return brokers[n], nil
}
```

## Behavior Analysis

### Candidate Selection
1. **Prefers replicas** - Only includes leader when `availableReplicas == 0`
2. **Sets advHost/advPort** - Required for connection validation in load-balanced environments
3. **Random selection** - Picks randomly from available replicas (or leader if no replicas)

### Probability Distribution
For a stream with 1 leader + 2 replicas:
- **Leader probability**: 0% (leader excluded when replicas available)
- **Each replica probability**: 50% (random selection between 2 replicas)

For a stream with 1 leader + 0 replicas:
- **Leader probability**: 100% (fallback when no replicas)

### Comparison with Other Clients

| Client | Leader Included? | Replica Preference | Configuration Option |
|--------|------------------|-------------------|---------------------|
| **.NET** | Only if no replicas | Guaranteed replica avoidance | None (automatic) |
| **Java** | Depends on flag | Statistical preference | `forceReplicaForConsumers` |
| **Go** | Only if no replicas | **Guaranteed replica avoidance** | **None (automatic)** |

## Implementation Details

### DNS Timeout Fix
**Problem**: 10-second DNS lookup timeout when using AddressResolver (load balancer)

**Solution**: Added `BrokerLeaderWithResolver` method that skips DNS lookup when AddressResolver is configured:
```go
func (c *Client) BrokerLeaderWithResolver(stream string, resolver *AddressResolver) (*Broker, error) {
    // ... metadata retrieval ...
    
    // If AddressResolver is configured, use it directly and skip DNS lookup
    if resolver != nil {
        streamMetadata.Leader.Host = resolver.Host
        streamMetadata.Leader.Port = strconv.Itoa(resolver.Port)
        return streamMetadata.Leader, nil
    }
    
    // Otherwise perform DNS lookup as before
    // ...
}
```

### Consumer Connection Validation
**Problem**: Load balancers may route connections to wrong nodes, breaking replica preference

**Solution**: Added validation loop matching producer logic in `environment.go`:
```go
// Validate that connection reached the intended broker (replica vs leader)
for clientResult.connectionProperties.host != leader.advHost ||
    clientResult.connectionProperties.port != leader.advPort {
    logs.LogDebug("connectionProperties host %s doesn't match advertised_host %s, advertised_port %s .. retry",
        clientResult.connectionProperties.host, leader.advHost, leader.advPort)
    clientResult.Close()
    clientResult = cc.newClientForConsumer(connectionName, leader, tcpParameters, saslConfiguration, rpcTimeout)
    err = clientResult.connect()
    if err != nil {
        return nil, err
    }
    time.Sleep(time.Duration(500+rand.Intn(1000)) * time.Millisecond)
}
```

### Retry Delay
Matches .NET client behavior: random delay between 500-1500ms (was fixed 1 second)

## Critical Changes Summary

1. **Replica preference**: Consumers now avoid leader when replicas are available
2. **DNS timeout fix**: Skip DNS lookup when AddressResolver is configured
3. **Connection validation**: Verify connection reaches intended replica through load balancer
4. **advHost/advPort initialization**: Set for all brokers to enable validation
5. **Retry delay**: Random 500-1500ms matching .NET client

## Implications

1. **Load distribution**: Consumers evenly distributed across replicas only
2. **Leader load**: Leader receives 0% of consumer connections (when replicas available)
3. **Automatic behavior**: No configuration needed, matches .NET client
4. **Load balancer support**: Connection validation ensures proper placement

## Testing

Verified with `single-consumer-on-leader-check.sh`:
- Stream leader: `rabbit@rmq1`
- 10 consumers created
- Result: 0 consumers on leader node
- All consumers distributed across replica nodes

## Status

✅ Implementation complete and tested
✅ Matches .NET client behavior
✅ Works correctly with load balancers
✅ No configuration required
