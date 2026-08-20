ARG RABBITMQ_DOCKER_TAG=rabbitmq:3.13.7-management

FROM ${RABBITMQ_DOCKER_TAG}

# iproute2 provides tc (netem), used to inject packet loss on a node's
# interface for the failure-detector experiment. iptables is included for
# alternative deterministic per-Nth-packet drop injection.
RUN apt-get update \
    && apt-get install -y --no-install-recommends iproute2 iptables \
    && rm -rf /var/lib/apt/lists/*

COPY --chown=rabbitmq:rabbitmq --chmod=0400 erlang.cookie /var/lib/rabbitmq/.erlang.cookie
COPY --chown=rabbitmq:rabbitmq enabled_plugins /etc/rabbitmq/
COPY --chown=rabbitmq:rabbitmq rabbitmq.conf /etc/rabbitmq/rabbitmq.conf
COPY --chown=rabbitmq:rabbitmq definitions.json /etc/rabbitmq/definitions.json

EXPOSE 4369 5672 15672 15692 25672 35672-35682
