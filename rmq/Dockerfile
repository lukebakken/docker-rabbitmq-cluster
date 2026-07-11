ARG RABBITMQ_DOCKER_TAG=rabbitmq:4.3-management-amazonlinux

FROM ${RABBITMQ_DOCKER_TAG}

# ENV LOG=debug RABBITMQ_FEATURE_FLAGS=khepri_db
ENV RABBITMQ_FEATURE_FLAGS=khepri_db

# Amazon Linux 2023 base: dnf, not apt-get. curl is already provided by
# curl-minimal (installing full curl conflicts), so it is omitted here.
RUN set -eux; \
    dnf install -y tcpdump net-tools iproute iputils bind-utils ldns-utils; \
    dnf clean all

COPY --chown=rabbitmq:rabbitmq --chmod=0400 erlang.cookie /var/lib/rabbitmq/.erlang.cookie
COPY --chown=rabbitmq:rabbitmq enabled_plugins /etc/rabbitmq/
COPY --chown=rabbitmq:rabbitmq rabbitmq.conf /etc/rabbitmq/rabbitmq.conf
# COPY --chown=rabbitmq:rabbitmq advanced.config /etc/rabbitmq/advanced.config

EXPOSE 4369 5672 15672 15692 25672 35672-35682
