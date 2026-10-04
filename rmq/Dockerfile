ARG RABBITMQ_DOCKER_TAG=rabbitmq:3.13.7-management

FROM ${RABBITMQ_DOCKER_TAG}

ARG CMQ_FIX=false

COPY --chown=rabbitmq:rabbitmq --chmod=0400 erlang.cookie /var/lib/rabbitmq/.erlang.cookie
COPY --chown=rabbitmq:rabbitmq enabled_plugins /etc/rabbitmq/
COPY --chown=rabbitmq:rabbitmq rabbitmq.conf /etc/rabbitmq/rabbitmq.conf
COPY --chown=rabbitmq:rabbitmq definitions.json /etc/rabbitmq/definitions.json

# When CMQ_FIX=true, replace the image's beams for the modules in cmq-fix/ with ones compiled
# from those sources, against this image's own headers and Erlang release.
COPY cmq-fix/*.erl /tmp/cmq-fix/
RUN if [ "$CMQ_FIX" = "true" ]; then \
        ERL_LIBS=/opt/rabbitmq/plugins erlc -Werror +debug_info \
            -I /opt/rabbitmq/plugins/rabbit-3.13.7/include \
            -o /opt/rabbitmq/plugins/rabbit-3.13.7/ebin \
            /tmp/cmq-fix/*.erl; \
    fi; \
    rm -rf /tmp/cmq-fix

EXPOSE 4369 5672 15672 15692 25672 35672-35682
