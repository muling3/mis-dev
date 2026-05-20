# mis-dev/Makefile — local orchestration for the MIS platform.
#
# Model: ONE repo per service / package (see `make repos`). mis-dev is NOT a
# monorepo root — it provides the shared infra (Postgres/Mongo/Redis/Kafka),
# the Kong API gateway, the architecture docs, and the scaffold generator.
#
# A developer:
#   1. clones mis-dev, runs `make infra-up`            (infra + Kong, once)
#   2. clones the ONE service repo they work on, and in THAT repo runs its
#      own Makefile: `make install-standalone` (or install-azure), `make dev`,
#      `make build`, `make docker-build`, ...
# Kong already routes /api/<domain> -> http://localhost:<port> on the host,
# so a service started on its port is reachable through the gateway with no
# Kong change.
#
# Platforms: Linux, macOS, and Windows (cmd.exe / PowerShell / Git Bash all
# work). Every recipe is a SINGLE command that delegates to a Node script
# under scripts/, so no shell built-ins (awk, tr, cut, for, [, …) are needed
# in any shell.

# Force a known shell. cmd.exe is always present on Windows even without
# Git for Windows; /bin/sh covers Linux + macOS.
ifeq ($(OS),Windows_NT)
  SHELL := cmd.exe
  .SHELLFLAGS := /C
else
  SHELL := /bin/sh
endif

COMPOSE := docker compose -f docker/docker-compose.yml

.PHONY: help infra-up infra-down infra-ps infra-logs reset \
        kafka-init kong-reload kong-token kong-metrics \
        urls repos scaffold clone-all dev up-all down-all

help:                  ## Show this help
	@node scripts/help.js

# ── Infrastructure (Docker Compose) ────────────────────
infra-up:              ## Start infra (Postgres, Mongo, Redis, Kafka, Kong) + Kafka topics
	$(COMPOSE) up -d
	$(MAKE) kafka-init
	@node -e "console.log('Infra up. URLs: make urls -- Logs: make infra-logs')"

infra-down:            ## Stop infra (keep volumes)
	$(COMPOSE) down

infra-ps:              ## Show infra container status
	$(COMPOSE) ps

infra-logs:            ## Tail infra logs
	$(COMPOSE) logs -f

reset:                 ## Nuke infra containers + volumes, then start fresh
	$(COMPOSE) down -v
	$(MAKE) infra-up

kafka-init:            ## Create Kafka topics
	node scripts/kafka-init.js

# ── Kong API gateway ───────────────────────────────────
kong-reload:           ## Reload Kong declarative config (no restart)
	@node scripts/kong-reload.js

kong-token:            ## Mint a PoC JWT accepted by Kong's jwt plugin
	@node scripts/mint-token.js

kong-metrics:          ## Show Kong Prometheus metrics (status listener :8100)
	@node scripts/kong-metrics.js

# ── Helpers ────────────────────────────────────────────
urls:                  ## Print local URLs cheat-sheet
	@node scripts/urls.js

repos:                 ## List every MIS repo + its clone URL
	@node scripts/repos.js

scaffold:              ## (Re)generate ALL service & package repos into ../ (recovery/offline)
	node scripts/scaffold.js

# ── Working with the actual repos (cloned next to mis-dev) ─────
clone-all:             ## Clone every repo into ../ (override REPO_URLS="a,b,c")
	@node scripts/clone-all.js $(REPO_URLS)

dev:                   ## Run ONE service through Kong: make dev s=auth
	@node scripts/dev.js $(s)

up-all:                ## Lead-dev: infra + every cloned service (background)
	@node scripts/up-all.js

down-all:              ## Stop background services + infra
	@node scripts/down-all.js
