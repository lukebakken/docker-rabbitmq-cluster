# Deliberately has no default: the Makefile is the one place that decides which
# version is built, and a default here would silently win whenever a build runs
# without --build-arg.
ARG RABBITMQ_DOCKER_TAG

FROM ${RABBITMQ_DOCKER_TAG}

# ENV LOG=debug RABBITMQ_FEATURE_FLAGS=khepri_db
ENV RABBITMQ_FEATURE_FLAGS=khepri_db

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install --yes --no-install-recommends curl tcpdump net-tools iproute2 iputils-ping dnsutils ldnsutils

COPY --chown=rabbitmq:rabbitmq --chmod=0400 erlang.cookie /var/lib/rabbitmq/.erlang.cookie
COPY --chown=rabbitmq:rabbitmq enabled_plugins /etc/rabbitmq/
COPY --chown=rabbitmq:rabbitmq rabbitmq.conf /etc/rabbitmq/rabbitmq.conf
# COPY --chown=rabbitmq:rabbitmq advanced.config /etc/rabbitmq/advanced.config

EXPOSE 4369 5672 15672 15692 25672 35672-35682
