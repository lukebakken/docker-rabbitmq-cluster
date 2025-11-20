# Docker-izing Java Stream Client App - Session Summary

**Date:** Thursday, November 20, 2025  
**Project:** docker-rabbitmq-cluster

## Overview

Successfully "Docker-ized" the `java-stream-client-app` following the same pattern used for the `dotnet-stream-client-app`.

## What Was Accomplished

### 1. Created Dockerfile for Java Application

**File:** `java-stream-client-app/Dockerfile`

- Multi-stage build using `eclipse-temurin:17-jdk` for build and `eclipse-temurin:17-jre` for runtime
- Caches Maven dependencies for faster rebuilds
- Builds shaded JAR with all dependencies
- Minimal runtime image

```dockerfile
FROM eclipse-temurin:17-jdk AS build
WORKDIR /build
COPY pom.xml mvnw ./
COPY .mvn .mvn
RUN ./mvnw dependency:go-offline
COPY src src
RUN ./mvnw package -DskipTests

FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /build/target/my-app-1.0-SNAPSHOT.jar app.jar
ENTRYPOINT ["java", "-jar", "app.jar"]
```

### 2. Updated pom.xml Configuration

**File:** `java-stream-client-app/pom.xml`

- Added main class configuration to maven-shade-plugin
- Added plugin to actual `<plugins>` section (not just `<pluginManagement>`)
- This fixed the "no main manifest attribute" error

```xml
<plugins>
  <plugin>
    <groupId>org.apache.maven.plugins</groupId>
    <artifactId>maven-shade-plugin</artifactId>
  </plugin>
</plugins>
```

### 3. Modified App.java for Docker Environment

**File:** `java-stream-client-app/src/main/java/com/mycompany/app/App.java`

#### Environment Variable Support
- Reads `RABBITMQ_HOST` (defaults to "localhost")
- Reads `RABBITMQ_PORT` (defaults to "5552")

#### Retry/Reconnection Logic
- 10 retry attempts with 5-second delays
- Logs each connection attempt
- Matches the .NET app's retry behavior
- Prevents immediate failure when haproxy isn't ready

#### Continuous Operation
- Continuously publishes messages (100ms delay between messages)
- Continuously consumes messages
- Runs indefinitely like the .NET app

#### Summary Logging
- Uses `AtomicLong` counters for thread-safe tracking
- Prints summary every 5 seconds: `Sent: X, Consumed: Y`
- No per-message logging (reduces noise)
- Matches .NET app's logging pattern

### 4. Updated docker-compose.yml

**File:** `docker-compose.yml`

Added new service:

```yaml
java-stream-client-app:
  build: java-stream-client-app
  networks:
    - rabbitnet
  environment:
    - RABBITMQ_HOST=haproxy
    - RABBITMQ_PORT=5552
  depends_on:
    - rmq0
    - rmq1
    - rmq2
    - haproxy
  restart: on-failure
  stop_grace_period: 30s
```

## Key Technical Decisions

1. **Base Image:** Used Eclipse Temurin (OpenJDK) instead of checking stream-perf-test base image
2. **Shade Plugin:** Required for creating executable JAR with all dependencies
3. **Thread Safety:** Used `AtomicLong` for counters accessed by multiple threads
4. **Daemon Thread:** Summary logging runs in daemon thread so it doesn't prevent JVM shutdown

## Issues Resolved

1. **"no main manifest attribute" error**
   - **Cause:** maven-shade-plugin only in `<pluginManagement>`, not executed
   - **Fix:** Added plugin to `<plugins>` section with main class configuration

2. **Connection refused on startup**
   - **Cause:** App tried to connect before haproxy was ready
   - **Fix:** Added retry logic with 10 attempts and 5-second delays

3. **App exiting immediately**
   - **Cause:** App published 10 messages then exited
   - **Fix:** Changed to continuous publishing loop

4. **Noisy logging**
   - **Cause:** Printed every consumed message
   - **Fix:** Implemented summary logging every 5 seconds

## Files Modified

1. `java-stream-client-app/Dockerfile` - **CREATED**
2. `java-stream-client-app/pom.xml` - **MODIFIED**
3. `java-stream-client-app/src/main/java/com/mycompany/app/App.java` - **MODIFIED**
4. `docker-compose.yml` - **MODIFIED**

## How to Use

### Build and Run
```bash
make up
```

### Clean Data
```bash
make clean
```

### View Logs
```bash
docker compose logs -f java-stream-client-app
```

## Expected Behavior

The Java app will:
1. Retry connecting to RabbitMQ up to 10 times
2. Create the "mystream" stream
3. Start a producer and consumer
4. Continuously publish messages (10 per second)
5. Continuously consume messages
6. Print summary statistics every 5 seconds

## Notes

- The app mirrors the .NET app's behavior for consistency
- Both apps use the same environment variables
- Both apps have the same retry logic
- Both apps run continuously with summary logging
- The `stream-perf-test` service was commented out in docker-compose.yml
