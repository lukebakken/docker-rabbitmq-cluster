FROM rabbitmq:3-management

RUN apt-get install --yes --fix-broken --fix-missing --verbose-versions --no-install-recommends dnsutils inetutils-ping iproute2

COPY --chown=rabbitmq:rabbitmq --chmod=0400 erlang.cookie /var/lib/rabbitmq/.erlang.cookie
COPY --chown=rabbitmq:rabbitmq enabled_plugins /etc/rabbitmq/
COPY --chown=rabbitmq:rabbitmq rabbitmq-env.conf /etc/rabbitmq/
COPY --chown=rabbitmq:rabbitmq rabbitmq.conf /etc/rabbitmq/rabbitmq.conf

EXPOSE 4369 5672 15672 15692 25672 35672-35682
