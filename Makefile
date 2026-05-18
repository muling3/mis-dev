# mis-dev/Makefile — local orchestration for the MIS PoC.
# In production each service lives in its own repo; here they're sibling
# workspaces under the parent dir, so PARENT/ resolves to the monorepo root.

SHELL          := /bin/bash
PARENT         := $(realpath ..)
REPOS_FILE     := repos.txt
SERVICES       := $(shell cat $(REPOS_FILE))
PACKAGES       := $(shell cd $(PARENT) && ls -d mis-pkg-* mis-proto 2>/dev/null)
LOCAL_FEED     := $(PARENT)/local-feed
COMPOSE        := docker compose -f docker/docker-compose.yml
SVC_COMPOSE    := docker compose -f docker/services.yml --env-file docker/.env

.PHONY: help bootstrap install-all build-pkgs pack-all \
        infra-up infra-down infra-logs infra-ps kafka-init kong-reload \
        kong-token kong-metrics \
        images-build services-up services-down services-ps services-logs \
        stack-up stack-down \
        prisma-generate-all prisma-deploy-all seed \
        dev dev-all build-all test-all lint-all typecheck-all clean-all reset \
        urls

# ── Help ────────────────────────────────────────────────
help:                  ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ── One-shot bootstrap ─────────────────────────────────
bootstrap: install-all build-pkgs infra-up ## Full first-time setup (install + build pkgs + infra)
	@echo ""
	@echo "Bootstrap complete. Try:"
	@echo "  make dev s=auth          # run a single service"
	@echo "  make dev-all             # run them all in tmux"

install-all:           ## npm install at the workspace root (links all services + @mis/*)
	cd $(PARENT) && npm install

build-pkgs:            ## Build all @mis/* packages (tsc -> dist/)
	cd $(PARENT) && npm run build:pkgs

pack-all:              ## Build + npm pack every @mis/* package into local-feed/ (Azure-feed stand-in)
	@rm -rf $(LOCAL_FEED) && mkdir -p $(LOCAL_FEED)
	@for p in $(PACKAGES); do \
	  echo "→ pack $$p"; \
	  $(MAKE) --no-print-directory -C $(PARENT)/$$p pack >/dev/null || exit 1; \
	  cp $(PARENT)/$$p/*.tgz $(LOCAL_FEED)/; \
	done
	@echo "Packed into $(LOCAL_FEED):" && ls -1 $(LOCAL_FEED)
	@echo "(Azure 'mis-npm' feed not wired yet — consumers can install from these tarballs.)"

# ── Infrastructure (Docker Compose) ────────────────────
infra-up:              ## Start infra (Postgres, Mongo, Redis, Kafka, Kong) + create Kafka topics
	$(COMPOSE) up -d
	$(MAKE) kafka-init
	@echo "Infra up. URLs: make urls — logs: make infra-logs"

infra-down:            ## Stop infra (keep volumes)
	$(COMPOSE) down

infra-ps:              ## Show infra container status
	$(COMPOSE) ps

infra-logs:            ## Tail infra logs
	$(COMPOSE) logs -f

kafka-init:            ## Create Kafka topics
	./scripts/kafka-init.sh

kong-reload:           ## Reload Kong declarative config
	curl -s -X POST http://localhost:8001/config \
	  -F config=@docker/kong/kong.yml | head -c 400; echo

kong-token:            ## Mint a PoC JWT accepted by Kong's jwt plugin
	@./scripts/mint-token.sh

kong-metrics:          ## Show Kong Prometheus metrics (status listener :8100)
	@curl -s http://localhost:8100/metrics | grep -E '^kong_(http_requests_total|request_latency)' | head -20 \
	  || echo "no metrics yet — is infra up and has traffic flowed through Kong?"

# ── Service containers (run the 8 services in Docker) ──────
# Ports 3001–3008 are published, so Kong's existing host upstreams keep
# working — no kong.yml edit, no Kong restart.

images-build:          ## Build Docker images for ALL 8 services from local code
	$(SVC_COMPOSE) build $(s)

services-up:           ## Run ALL services from EXISTING images (no build; run images-build first)
	$(SVC_COMPOSE) up -d --no-build $(s)
	@echo "Services up on :3001–:3008. Kong unchanged — verify: make urls"

services-down:         ## Stop & remove the service containers (infra untouched)
	$(SVC_COMPOSE) down

services-ps:           ## Show service container status
	$(SVC_COMPOSE) ps

services-logs:         ## Tail service logs
	$(SVC_COMPOSE) logs -f $(s)

stack-up: infra-up services-up   ## One shot: infra (+topics) then all services from existing images

stack-down: services-down infra-down ## Stop everything (services then infra)

# ── Per-service fan-out (preserves the Makefile contract) ──
prisma-generate-all:   ## Run prisma generate in every service (stubbed)
	@for s in $(SERVICES); do \
	  $(MAKE) -C $(PARENT)/$$s prisma-generate 2>/dev/null || echo "  (skip $$s)"; \
	done

prisma-deploy-all:     ## Apply prisma migrations (stubbed)
	@for s in $(SERVICES); do \
	  $(MAKE) -C $(PARENT)/$$s prisma-deploy 2>/dev/null || echo "  (skip $$s)"; \
	done

build-all:             ## nest build for every service
	@for s in $(SERVICES); do \
	  echo "→ build $$s"; \
	  $(MAKE) -C $(PARENT)/$$s build; \
	done

test-all:              ## test every service (stubbed)
	@for s in $(SERVICES); do \
	  $(MAKE) -C $(PARENT)/$$s test || true; \
	done

lint-all:              ## lint every service (stubbed)
	@for s in $(SERVICES); do \
	  $(MAKE) -C $(PARENT)/$$s lint || true; \
	done

typecheck-all:         ## tsc --noEmit per service
	@for s in $(SERVICES); do \
	  echo "→ typecheck $$s"; \
	  $(MAKE) -C $(PARENT)/$$s typecheck || true; \
	done

seed:                  ## Seed databases (stubbed)
	@echo "TODO: implement scripts/seed.ts when Prisma schemas land"

# ── Dev runners ────────────────────────────────────────
dev:                   ## Run a single service: make dev s=auth
	@test -n "$(s)" || (echo "Usage: make dev s=auth"; exit 1)
	$(MAKE) -C $(PARENT)/mis-$(s)-service dev

dev-all:               ## Run every service in watch mode (requires tmux)
	./scripts/dev-all.sh

clean-all:             ## Remove dist + node_modules in every workspace
	@for s in $(SERVICES); do \
	  $(MAKE) -C $(PARENT)/$$s clean || true; \
	done
	rm -rf $(PARENT)/node_modules

reset:                 ## Nuke containers + volumes and rebootstrap
	$(COMPOSE) down -v
	$(MAKE) bootstrap

urls:                  ## Print local URLs cheat-sheet
	@cat docs/urls.txt 2>/dev/null || cat <<'EOF'
	Service URLs (direct + via Kong on :8000):
	  Auth          http://localhost:3001/health    http://localhost:8000/api/auth/health
	  Registration  http://localhost:3002/health    http://localhost:8000/api/registration/health
	  Case          http://localhost:3003/health    http://localhost:8000/api/cases/health
	  Sandbox       http://localhost:3004/health    http://localhost:8000/api/sandbox/health
	  Notification  http://localhost:3005/health    http://localhost:8000/api/notifications/health
	  Reporting     http://localhost:3006/health    http://localhost:8000/api/reporting/health
	  Document      http://localhost:3007/health    http://localhost:8000/api/documents/health
	  Admin         http://localhost:3008/health    http://localhost:8000/api/admin/health
	Infra UIs:
	  Kong admin    http://localhost:8001
	  Postgres      localhost:5432  (mis/mis, db mis_dev)
	  Mongo         localhost:27017
	  Redis         localhost:6379
	  Kafka         localhost:29092 (host listener)
	EOF
