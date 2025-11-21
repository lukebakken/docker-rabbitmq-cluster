# RabbitMQ Stream Client Investigation - Session Summary

## Overview
Investigation of RabbitMQ Stream client behavior with haproxy load balancer in docker-compose environment to understand connection distribution patterns and verify whether consumers connect to stream leader nodes.

## Environment Configuration
- **RabbitMQ Cluster**: 3 nodes (rmq0, rmq1, rmq2)
- **Load Balancer**: haproxy with round-robin distribution
- **Client Applications**: 
  - Java Stream client
  - .NET Stream client
  - stream-perf-test (Go-based)
- **Initial Setup**: 2 producers, 5 consumers per app
- **Final Setup**: 2 producers, 10 consumers per app

## Key Findings

### Connection Distribution Patterns
- With round-robin load balancing and specific consumer counts (5, 7), a deterministic pattern prevented consumers from landing on leader nodes across 20+ iterations
- Connection count significantly affects distribution - changing from 5 to 7 to 10 consumers altered the pattern
- Producers consistently landed on leader nodes while consumers landed on replicas due to connection order
- After environment restart with 10 consumers, consumers successfully connected to leader nodes in some cases

### Stream Client Behavior
- **Java Stream Client**: Has `forceReplicaForConsumers` flag (default: false), allowing consumers on leaders
- **.NET Stream Client**: No such restriction, allows consumers on leaders by default
- **Critical Limitation**: When connecting through a load balancer, stream clients lose their built-in optimization capabilities (producers to leaders, consumers to replicas)
- Applications cannot choose specific nodes when connecting through haproxy - all routing is determined by haproxy's round-robin algorithm

### Load Balancer Impact
- Round-robin distribution creates deterministic connection patterns based on total connection count
- The order of connection creation (locators → producers → consumers) affects which nodes receive which connection types
- Load balancers eliminate the stream clients' intelligent node selection capabilities

## Tools and Scripts Developed

### check-consumer-leader-connections.sh
**Purpose**: Continuously monitor for consumers connecting to stream leader nodes, restarting applications between iterations

**Key Features**:
- Iterative checking with automatic application restarts
- Uses PID matching to associate consumers with connection nodes
- Eliminates dependency on application-specific connection naming patterns
- Color-coded logging with debug mode support
- Associative arrays for efficient stream leader tracking
- 30-second wait between iterations for connections to stabilize

**Evolution**:
- Initially used connection name pattern matching
- Updated to use PID-based matching for 100% precision
- Removed application-specific logic (connection name patterns)

### check-consumers-on-leaders.sh
**Purpose**: One-time check to identify if any consumers are currently connected to their stream's leader node

**Key Features**:
- Uses PID matching to precisely associate consumers with nodes
- Builds PID-to-node mapping from `list_stream_connections`
- Matches consumer PIDs from `list_stream_consumers` to their nodes
- Checks if consumer node matches stream leader node
- Reports total count of consumers on leader nodes

**Technical Approach**:
1. Get stream leaders from `list_queues`
2. Build PID→node mapping from `list_stream_connections`
3. For each stream, get consumer PIDs from `list_stream_consumers`
4. Look up each consumer's node via PID mapping
5. Compare consumer node to stream leader node

## Code Changes

### Java Application (App.java)
- Added `connection_name` client property for connection identification
- Increased consumer count from 5 → 7 → 10 to break deterministic patterns
- Added graceful shutdown handling with cleanup of producers/consumers
- Added 100ms delay between messages for rate limiting

### C# Application (Program.cs)
- Added `ClientProvidedName` property for connection identification
- Set `ProducersPerConnection` and `ConsumersPerConnection` to 1
- Increased consumer count to match Java app
- Added graceful shutdown handling with cleanup
- Added 100ms delay between messages for rate limiting

### Haproxy Configuration
- Changed logging from syslog to stdout: `log stdout format raw local0 info`
- Maintained round-robin load balancing algorithm

## Technical Insights

### RabbitMQ Stream Commands Used
- `rabbitmqctl list_queues name type leader --formatter=json` - Get stream leaders
- `rabbitmqctl list_stream_connections pid node --formatter=json` - Get connection PIDs and nodes
- `rabbitmqctl list_stream_consumers stream connection_pid --formatter=json` - Get consumer stream subscriptions and PIDs
- `rabbitmqctl list_stream_connections client_properties node --formatter=json` - Get connection names (legacy approach)

### PID Matching Approach
The breakthrough improvement was using PIDs to associate consumers with their connection nodes:
1. `list_stream_connections` provides `pid` and `node` for each connection
2. `list_stream_consumers` provides `connection_pid` for each consumer
3. Matching these PIDs gives precise consumer→node mapping
4. This eliminates need for connection name patterns or application-specific logic

### Bash Scripting Techniques
- Associative arrays for efficient lookups: `declare -A stream_leaders`
- Process substitution for variable persistence: `done < <(command)`
- Color-coded output using ANSI escape codes
- Debug mode with conditional logging
- Proper error handling with `set -o errexit -o nounset -o pipefail`

## Limitations Discovered

### Load Balancer Constraints
- Stream clients lose intelligent node selection when behind load balancers
- Round-robin creates deterministic patterns that may not align with optimal placement
- No way for clients to request specific nodes through the load balancer
- Connection order matters significantly with round-robin distribution

### Workarounds Attempted
- Changing consumer counts (5 → 7 → 10) to break patterns
- Restarting applications to get different connection sequences
- Both approaches showed that distribution is mathematically deterministic

### Alternative Approaches Not Tested
- Changing haproxy algorithm from `roundrobin` to `leastconn`
- Adding randomness to haproxy's selection
- Randomizing connection order in applications
- Using direct node connections instead of load balancer

## Environment Management
- `make up` - Bring up cluster
- `make clean` - Clean data
- `docker compose restart <service>` - Restart specific services
- `docker compose exec rmq0 <command>` - Execute commands on RabbitMQ nodes

## Conclusion
The investigation revealed that load balancers fundamentally change how stream clients connect to RabbitMQ clusters. While the clients have built-in intelligence for optimal node selection (producers to leaders, consumers to replicas), this capability is lost when connections are routed through a load balancer using round-robin distribution. The PID-based matching approach provides a reliable, application-agnostic method for verifying consumer placement across cluster nodes.
