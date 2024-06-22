ARG RABBITMQ_DOCKER_TAG=rabbitmq:3-management

FROM ${RABBITMQ_DOCKER_TAG}

ENV LOG=debug

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install --yes --no-install-recommends curl tcpdump net-tools iproute2

COPY --chown=rabbitmq:rabbitmq --chmod=0400 erlang.cookie /var/lib/rabbitmq/.erlang.cookie
COPY --chown=rabbitmq:rabbitmq enabled_plugins /etc/rabbitmq/
COPY --chown=rabbitmq:rabbitmq rabbitmq-env.conf /etc/rabbitmq/
COPY --chown=rabbitmq:rabbitmq rabbitmq.conf /etc/rabbitmq/rabbitmq.conf
# COPY --chown=rabbitmq:rabbitmq advanced.config /etc/rabbitmq/advanced.config

COPY --chown=rabbitmq:rabbitmq inter_node_tls.config /etc/rabbitmq/
COPY --chown=rabbitmq:rabbitmq ca_certificate.pem /etc/rabbitmq/
COPY --chown=rabbitmq:rabbitmq *rmq2.local*.pem /etc/rabbitmq/

EXPOSE 4369 5671 5672 15671 15672 15692 25672 35672-35682
