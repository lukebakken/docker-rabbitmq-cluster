ARG RABBITMQ_DOCKER_TAG=rabbitmq:3.13.7-management

FROM ${RABBITMQ_DOCKER_TAG}

# RUN set -eux; \
#     export DEBIAN_FRONTEND=noninteractive; \
#     apt-get update; \
#     apt-get install --yes --no-install-recommends curl tcpdump net-tools iproute2 iputils-ping dnsutils ldnsutils

COPY --chown=rabbitmq:rabbitmq --chmod=0400 erlang.cookie /var/lib/rabbitmq/.erlang.cookie
COPY --chown=rabbitmq:rabbitmq enabled_plugins /etc/rabbitmq/
COPY --chown=rabbitmq:rabbitmq rabbitmq-env.conf /etc/rabbitmq/
COPY --chown=rabbitmq:rabbitmq rabbitmq.conf /etc/rabbitmq/rabbitmq.conf
COPY --chown=rabbitmq:rabbitmq advanced.config /etc/rabbitmq/advanced.config
COPY --chown=rabbitmq:rabbitmq definitions.json /etc/rabbitmq/definitions.json

EXPOSE 4369 5672 15672 15692 25672 35672-35682
