.PHONY: down image up

down:
	docker compose down

image:
	docker build --pull --tag rabbitmq-local:latest .

up:
	docker compose up --detach
