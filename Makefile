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

SHELL   := /bin/bash
COMPOSE := docker compose -f docker/docker-compose.yml

.PHONY: help infra-up infra-down infra-ps infra-logs reset \
        kafka-init kong-reload kong-token kong-metrics \
        urls repos scaffold

help:                  ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ── Infrastructure (Docker Compose) ────────────────────
infra-up:              ## Start infra (Postgres, Mongo, Redis, Kafka, Kong) + Kafka topics
	$(COMPOSE) up -d
	$(MAKE) kafka-init
	@echo "Infra up. URLs: make urls — logs: make infra-logs"

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
	./scripts/kafka-init.sh

# ── Kong API gateway ───────────────────────────────────
kong-reload:           ## Reload Kong declarative config (no restart)
	curl -s -X POST http://localhost:8001/config \
	  -F config=@docker/kong/kong.yml | head -c 400; echo

kong-token:            ## Mint a PoC JWT accepted by Kong's jwt plugin
	@./scripts/mint-token.sh

kong-metrics:          ## Show Kong Prometheus metrics (status listener :8100)
	@curl -s http://localhost:8100/metrics | grep -E '^kong_(http_requests_total|request_latency)' | head -20 \
	  || echo "no metrics yet — is infra up and has traffic flowed through Kong?"

# ── Helpers ────────────────────────────────────────────
urls:                  ## Print local URLs cheat-sheet
	@cat docs/urls.txt 2>/dev/null || echo "(docs/urls.txt missing)"

repos:                 ## List every MIS repo + its clone URL
	@echo "Clone mis-dev (this repo) for infra/docs; clone the ONE service you work on:"
	@echo
	@awk 'NF && $$1 !~ /^#/ {printf "  %-26s %s\n", $$1, $$2}' repos.txt

scaffold:              ## (Re)generate ALL service & package repos into ../ (recovery/offline)
	@echo "This regenerates the full set of repos in $$(realpath ..) — for"
	@echo "offline bootstrap/recovery only. Normally you clone repos individually."
	./scripts/scaffold.sh
