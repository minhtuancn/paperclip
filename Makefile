# Makefile — admin commands for the Paperclip LAN deployment.
#
# All commands use the same two compose files and the local .env.
# NOTE: `make down` intentionally never uses -v. See DEPLOYMENT.md.

SHELL := /bin/bash
COMPOSE_ARGS := --env-file .env -f docker/docker-compose.quickstart.yml -f docker/docker-compose.production.yml

.PHONY: status logs up down restart backup update-check update config

status:
	@./scripts/status.sh

logs:
	@./scripts/logs.sh 200

up:
	@docker compose $(COMPOSE_ARGS) up -d

down:
	@docker compose $(COMPOSE_ARGS) down

restart:
	@docker compose $(COMPOSE_ARGS) restart paperclip

backup:
	@./scripts/backup.sh

update-check:
	@./scripts/update.sh --check

update:
	@./scripts/update.sh

config:
	@docker compose $(COMPOSE_ARGS) config | grep -vE 'BETTER_AUTH_SECRET|API_KEY' || true
