# Makefile — admin commands for the Paperclip LAN deployment.
#
# All commands use the same two compose files and the local .env.
# NOTE: `make down` intentionally never uses -v. See DEPLOYMENT.md.

SHELL := /bin/bash

.PHONY: status logs up down restart backup update-check update config

status:
	@./scripts/status.sh

logs:
	@./scripts/logs.sh 200

up:
	@./scripts/dc up -d

down:
	@./scripts/dc down

restart:
	@./scripts/dc restart paperclip

backup:
	@./scripts/backup.sh

update-check:
	@./scripts/update.sh --check

update:
	@./scripts/update.sh

config:
	@./scripts/dc config | grep -vE 'BETTER_AUTH_SECRET|API_KEY' || true
