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
PARENT  := $(realpath ..)

# domain:port:clone-dir  (clone-dir = basename of the repo's git URL)
SVC_MAP := auth:3001:mis-auth-svc registration:3002:mis-registration-svc \
           case:3003:mis-case-svc sandbox:3004:mis-sandbox-svc \
           notification:3005:mis-notification-svc document:3007:mis-document-svc \
           admin:3008:mis-admin-svc

# Comma-separated clone URLs. Default = every repo in repos.txt except mis-dev.
# Override:  make clone-all REPO_URLS="git@…/a.git,git@…/b.git"
REPO_URLS ?= $(shell awk 'NF && $$1!~/^#/ && $$1!="mis-dev"{printf "%s,",$$2}' repos.txt)

.PHONY: help infra-up infra-down infra-ps infra-logs reset \
        kafka-init kong-reload kong-token kong-metrics \
        urls repos scaffold clone-all dev up-all down-all

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

# ── Working with the actual repos (cloned next to mis-dev) ─────
clone-all:             ## Clone every repo into ../ (override REPO_URLS="a,b,c")
	@cd $(PARENT) && for u in $$(echo "$(REPO_URLS)" | tr ',' ' '); do \
	  [ -z "$$u" ] && continue; \
	  d=$$(basename "$$u" .git); \
	  if [ -d "$$d/.git" ]; then echo "  exists  $$d"; \
	  else echo "  clone   $$d"; git clone -q "$$u" "$$d" || echo "  FAILED  $$d"; fi; \
	done

# Internal: ensure service <s> is cloned next to mis-dev and deps installed.
define _ensure_service
	set -e; entry=""; \
	for m in $(SVC_MAP); do [ "$${m%%:*}" = "$(s)" ] && entry="$$m"; done; \
	[ -n "$$entry" ] || { echo "unknown service '$(s)'. one of: $(foreach m,$(SVC_MAP),$(firstword $(subst :, ,$m)))"; exit 1; }; \
	port=$$(echo "$$entry" | cut -d: -f2); dir=$$(echo "$$entry" | cut -d: -f3); \
	if [ ! -d "$(PARENT)/$$dir/.git" ]; then \
	  url=$$(awk -v n="mis-$(s)-service" '$$1==n{print $$2}' repos.txt); \
	  echo "→ cloning $$dir"; git clone -q "$$url" "$(PARENT)/$$dir"; fi; \
	[ -d "$(PARENT)/$$dir/node_modules" ] || { echo "→ installing deps ($$dir)"; $(MAKE) -C "$(PARENT)/$$dir" install-standalone; }
endef

dev:                   ## Run ONE service through Kong: make dev s=auth
	@test -n "$(s)" || { echo "usage: make dev s=<auth|registration|case|sandbox|notification|document|admin>"; exit 1; }
	$(MAKE) infra-up
	@$(_ensure_service); \
	  port=$$(for m in $(SVC_MAP); do [ "$${m%%:*}" = "$(s)" ] && echo $$m; done | cut -d: -f2); \
	  dir=$$(for m in $(SVC_MAP); do [ "$${m%%:*}" = "$(s)" ] && echo $$m; done | cut -d: -f3); \
	  echo "→ $(s) on :$$port  (via Kong: http://localhost:8000/api/$(s)/health)"; \
	  PORT=$$port $(MAKE) -C "$(PARENT)/$$dir" dev

up-all:                ## Lead-dev: infra + every cloned service (background)
	$(MAKE) infra-up
	@for m in $(SVC_MAP); do \
	  s=$${m%%:*}; port=$$(echo $$m|cut -d: -f2); dir=$$(echo $$m|cut -d: -f3); \
	  if [ ! -d "$(PARENT)/$$dir/.git" ]; then echo "  skip $$s (not cloned — make clone-all)"; continue; fi; \
	  [ -d "$(PARENT)/$$dir/node_modules" ] || $(MAKE) -C "$(PARENT)/$$dir" install-standalone; \
	  $(MAKE) -C "$(PARENT)/$$dir" build >/dev/null; \
	  ( cd "$(PARENT)/$$dir" && PORT=$$port nohup node dist/main.js >/tmp/mis-$$s.log 2>&1 & ); \
	  echo "  started $$s → :$$port (log: /tmp/mis-$$s.log)"; \
	done
	@echo "All up. Through Kong: http://localhost:8000/api/<domain>/...  —  stop: make down-all"

down-all:              ## Stop background services + infra
	@for m in $(SVC_MAP); do \
	  port=$$(echo $$m|cut -d: -f2); \
	  pid=$$(ss -ltnp 2>/dev/null | grep ":$$port " | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2); \
	  [ -n "$$pid" ] && { kill "$$pid" 2>/dev/null && echo "  stopped :$$port"; }; \
	done; true
	$(MAKE) infra-down
