# Exact command sequence (as run)

This is the literal sequence of commands used to produce the results in [aten-experiment.md](aten-experiment.md), including dead-ends and mistakes, so the runs can be reproduced or audited exactly. Where the `make` wrappers exist they are noted, but several steps used raw `docker` / `tc` commands directly (especially the multi-node loss orchestration), and those raw commands are what actually ran.

Host: single Linux host with Docker. All `docker compose` commands run from the repo root. Node interface inside containers is `eth0`. Container memory limit is 8 GB (`mem_limit: 8g`).

## 1. Build and bring up the cluster

```
docker compose build --build-arg RABBITMQ_DOCKER_TAG=rabbitmq:3.13.7-management
sudo chown -R '999:999' data log
docker compose up -d rmq0 rmq1 rmq2
```

Wait for boot and confirm the cluster formed:

```
for n in rmq0 rmq1 rmq2; do docker compose exec -T "$n" rabbitmqctl await_startup --timeout 60 < /dev/null; done
docker compose exec -T rmq0 rabbitmqctl cluster_status < /dev/null
```

## 2. Runtime assumption checks

```
# interface name (expect eth0)
docker compose exec -T rmq0 ip -o -4 addr show < /dev/null

# aten application running (expect {aten,"Erlang node failure detector","0.6.0"})
docker compose exec -T rmq0 rabbitmqctl eval 'lists:keyfind(aten, 1, application:which_applications()).' < /dev/null

# aten data shape on each node (expect #{peer => 0.0, peer => 0.0})
for n in rmq0 rmq1 rmq2; do docker compose exec -T "$n" rabbitmqctl eval 'aten_sink:get_failure_probabilities().' < /dev/null; done

# version and tc present
docker compose exec -T rmq0 rabbitmqctl eval '{rabbit, _, V} = lists:keyfind(rabbit,1,application:which_applications()), V.' < /dev/null
docker compose exec -T rmq0 sh -c 'command -v tc && tc -V' < /dev/null
```

## 3. Smoke test (steady loss, no load)

```
./netem/loss.sh rmq0 60
sleep 15
for n in rmq0 rmq1 rmq2; do docker compose exec -T "$n" rabbitmqctl eval 'aten_sink:get_failure_probabilities().' < /dev/null; done
./netem/clear.sh rmq0
```

Observed: rmq1 and rmq2 both drove rmq0 to ~1.0 within 15s while seeing each other at 0.0.

## 4. Experiment 1: single faulty node under load

Start the load services and confirm queues exist:

```
docker compose up -d haproxy perf-test perf-test-qq
sleep 25
docker compose exec -T rmq0 rabbitmqctl list_queues name type messages --no-table-headers < /dev/null
```

Run the injector in the background and capture for 240s in the foreground, then stop and clear:

```
rm -f out/aten-capture.log
./netem/loss-periodic.sh rmq0 48 5 10 > /tmp/inject.log 2>&1 &
inject_pid=$!
./netem/capture-aten.sh 240 1
kill "$inject_pid"; ./netem/clear.sh rmq0
```

Capture landed in `out/aten-capture.log` (preserved as `out/aten-run1.log`).

Mistake to avoid: do NOT clean up the injector with `pkill -f 'loss-periodic'`. The pattern matches the argv of the running cleanup command itself and kills the current shell. Stop it by the PID captured above, and verify the qdisc directly:

```
docker compose exec -T rmq0 tc qdisc show dev eth0 < /dev/null   # expect: qdisc noqueue (cleared)
```

## 5. busy_dist_port attempts (dead-end, documented)

Goal was to reproduce cluster-wide distribution congestion via heavy mirrored load. It did not work on single-host loopback. First heavy-load attempt (large messages, high fan-out):

```
docker run --rm -d --name heavyload --network rabbitnet pivotalrabbitmq/perf-test:latest \
  --uri amqp://haproxy \
  --queue-pattern 'heavy-%03d' --queue-pattern-from 0 --queue-pattern-to 19 \
  --queue-args x-queue-type=classic \
  --producers 20 --consumers 20 \
  --size 100000 --rate 80 \
  --flag persistent --flag mandatory --auto-delete false
sleep 60
for n in rmq0 rmq1 rmq2; do grep -rc 'busy_dist_port' log/$n/*.log; done   # all 0
```

Then a deliberately shrunk distribution buffer via a throwaway override, to try to force `busy_dist_port`:

```
cat > docker-compose.override.yml << 'EOF'
services:
  rmq0:
    environment:
      RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS: "+zdbbl 32"
  rmq1:
    environment:
      RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS: "+zdbbl 32"
  rmq2:
    environment:
      RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS: "+zdbbl 32"
EOF

docker stop heavyload
docker compose up -d rmq0 rmq1 rmq2     # recreate with the override
for n in rmq0 rmq1 rmq2; do docker compose exec -T "$n" rabbitmqctl await_startup --timeout 90 < /dev/null; done
docker compose exec -T rmq0 rabbitmqctl eval 'erlang:system_info(dist_buf_busy_limit).' < /dev/null   # 32768
```

Recreating all three at once raced and rmq2 crashed on boot-time cluster sync; restarting it alone recovered it:

```
docker compose up -d rmq2
docker compose exec -T rmq2 rabbitmqctl await_startup --timeout 90 < /dev/null
```

Second heavy-load attempt against the shrunk buffer still produced zero `busy_dist_port` (loopback drains faster than load fills):

```
docker rm -f heavyload
docker run --rm -d --name heavyload --network rabbitnet pivotalrabbitmq/perf-test:latest \
  --uri amqp://haproxy \
  --queue-pattern 'heavy-%03d' --queue-pattern-from 0 --queue-pattern-to 9 \
  --queue-args x-queue-type=classic \
  --producers 10 --consumers 10 \
  --size 100000 --rate 30 \
  --flag persistent --auto-delete false
sleep 45
for n in rmq0 rmq1 rmq2; do grep -rc 'busy_dist_port' log/$n/*.log; done   # still 0
```

Revert the override and restore default buffer:

```
rm -f docker-compose.override.yml
docker compose up -d rmq0 rmq1 rmq2
for n in rmq0 rmq1 rmq2; do docker compose exec -T "$n" rabbitmqctl await_startup --timeout 90 < /dev/null; done
docker compose exec -T rmq0 rabbitmqctl eval 'erlang:system_info(dist_buf_busy_limit).' < /dev/null   # 131072000 (default)
```

Conclusion: `busy_dist_port` is not reproducible on single-host docker; congestion was instead modelled directly with uniform netem loss (next section).

## 6. Experiment 2: masking (uniform loss, then one node worse)

Light background load for realism:

```
docker run --rm -d --name heavyload --network rabbitnet pivotalrabbitmq/perf-test:latest \
  --uri amqp://haproxy \
  --queue-pattern 'heavy-%03d' --queue-pattern-from 0 --queue-pattern-to 9 \
  --queue-args x-queue-type=classic \
  --producers 10 --consumers 10 \
  --size 20000 --rate 40 \
  --flag persistent --auto-delete false
```

The masking runs applied loss to all three nodes and toggled one node, using raw `tc` (not the single-node `make` wrappers) so multiple nodes could be driven together. The orchestration ran in the background as one self-terminating job, writing phase timestamps so the capture could be segmented afterward.

First masking run (8% uniform, then rmq0 to 40%). Note: this run OOM-killed a node (see caveat below), so a gentler run was done next.

```
rm -f out/aten-capture.log /tmp/cap2_phases.log
{
  ./netem/capture-aten.sh 210 1 > /tmp/cap2.log 2>&1 &
  capid=$!
  echo "$(date -u +%H:%M:%SZ) baseline_noloss" >> /tmp/cap2_phases.log
  sleep 15
  echo "$(date -u +%H:%M:%SZ) uniform_8pct_all" >> /tmp/cap2_phases.log
  for n in rmq0 rmq1 rmq2; do docker compose exec -T "$n" tc qdisc replace dev eth0 root netem loss 8% < /dev/null; done
  sleep 70
  echo "$(date -u +%H:%M:%SZ) rmq0_40pct_others_8pct" >> /tmp/cap2_phases.log
  docker compose exec -T rmq0 tc qdisc replace dev eth0 root netem loss 40% < /dev/null
  sleep 70
  echo "$(date -u +%H:%M:%SZ) clear_all" >> /tmp/cap2_phases.log
  for n in rmq0 rmq1 rmq2; do docker compose exec -T "$n" tc qdisc del dev eth0 root < /dev/null 2>/dev/null; done
  wait "$capid"
} > /tmp/cap2_orch.log 2>&1
```

Gentler, clean masking run (4% uniform, then rmq0 to 25%); all three nodes survived. This is the run whose numbers are reported:

```
docker ps --format '{{.Names}}' | grep -q heavyload || docker run --rm -d --name heavyload --network rabbitnet pivotalrabbitmq/perf-test:latest --uri amqp://haproxy --queue-pattern 'heavy-%03d' --queue-pattern-from 0 --queue-pattern-to 9 --queue-args x-queue-type=classic --producers 10 --consumers 10 --size 20000 --rate 40 --flag persistent --auto-delete false

rm -f out/aten-capture.log /tmp/cap3_phases.log
{
  ./netem/capture-aten.sh 150 1 > /tmp/cap3.log 2>&1 &
  capid=$!
  echo "$(date -u +%H:%M:%SZ) baseline" >> /tmp/cap3_phases.log
  sleep 12
  echo "$(date -u +%H:%M:%SZ) uniform_4pct" >> /tmp/cap3_phases.log
  for n in rmq0 rmq1 rmq2; do docker compose exec -T "$n" tc qdisc replace dev eth0 root netem loss 4% < /dev/null; done
  sleep 55
  echo "$(date -u +%H:%M:%SZ) rmq0_25pct" >> /tmp/cap3_phases.log
  docker compose exec -T rmq0 tc qdisc replace dev eth0 root netem loss 25% < /dev/null
  sleep 55
  echo "$(date -u +%H:%M:%SZ) clear" >> /tmp/cap3_phases.log
  for n in rmq0 rmq1 rmq2; do docker compose exec -T "$n" tc qdisc del dev eth0 root < /dev/null 2>/dev/null; done
  wait "$capid"
  echo "nodes_up: $(for n in rmq0 rmq1 rmq2; do docker compose exec -T $n rabbitmqctl await_startup --timeout 3 < /dev/null > /dev/null 2>&1 && echo -n "$n "; done)" >> /tmp/cap3_phases.log
} > /tmp/cap3_orch.log 2>&1
```

The capture was preserved as `out/aten-run3-masking.log`, and the phase timestamps in `/tmp/cap3_phases.log` were used to segment it per phase for analysis.

## 7. OOM caveat

During the heavier-loss runs, a node's `beam.smp` was OOM-killed at ~8.3 GB against the 8 GB `mem_limit` (visible only in host `dmesg`, since compose replaces the dead container with a fresh one). If a node disappears mid-run, check the host kernel log and restart it:

```
docker compose logs rmq2 --tail 20
docker compose up -d rmq2
docker compose exec -T rmq2 rabbitmqctl await_startup --timeout 90 < /dev/null
```

Keep messages small (`--size 20000`) or loss moderate to avoid this under `ha-mode:all` with persistent messages.

## 8. Analysis and teardown

Analysis parsed `out/aten-capture.log` (or the preserved copies) into an observer x peer probability series per phase, using the phase timestamps to segment. Teardown:

```
docker rm -f heavyload
docker compose down
```
