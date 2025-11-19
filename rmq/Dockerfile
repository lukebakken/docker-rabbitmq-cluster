ARG RABBITMQ_DOCKER_TAG=rabbitmq:4.1-management-alpine
FROM ${RABBITMQ_DOCKER_TAG}

ARG RABBITMQ_DELAYED_MESSAGE_PLUGIN_VERSION=4.1.0

COPY --chown=rabbitmq:rabbitmq --chmod=0400 erlang.cookie /var/lib/rabbitmq/.erlang.cookie
COPY --chown=rabbitmq:rabbitmq enabled_plugins /etc/rabbitmq/
COPY --chown=rabbitmq:rabbitmq rabbitmq.conf /etc/rabbitmq/rabbitmq.conf

EXPOSE 4369 5672 15672 15692 25672 35672-35682

RUN set -eux; \
    apk update; \
    apk upgrade; \
    apk add curl; \
    curl --location --output /opt/rabbitmq/plugins/rabbitmq_delayed_message_exchange.ez https://github.com/rabbitmq/rabbitmq-delayed-message-exchange/releases/download/v$RABBITMQ_DELAYED_MESSAGE_PLUGIN_VERSION/rabbitmq_delayed_message_exchange-$RABBITMQ_DELAYED_MESSAGE_PLUGIN_VERSION.ez
