.PHONY: clean down fresh import up

clean: down
	docker system prune --force

down:
	docker compose down

fresh: down clean up import

import:
	/bin/sh $(CURDIR)/import-defs.sh

up:
	docker compose up --detach
