# 09 — Local Development

## Table of Contents

1. [Mental Model](#1-mental-model)
2. [Prerequisites](#2-prerequisites)
3. [First-Time Bootstrap](#3-first-time-bootstrap)
4. [The Parent Folder Layout](#4-the-parent-folder-layout)
5. [Root Makefile (`mis-dev/Makefile`)](#5-root-makefile-mis-devmakefile)
6. [Docker Compose Stack](#6-docker-compose-stack)
7. [Per-Service Workflow](#7-per-service-workflow)
8. [Environment Variables](#8-environment-variables)
9. [Seed Data](#9-seed-data)
10. [Debugging](#10-debugging)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Mental Model

```
~/code/mis/                      ← parent directory you choose
├── mis-dev/                     ← orchestration repo (root Makefile + Compose)
├── mis-auth-service/
├── mis-registration-service/
├── mis-case-service/
├── mis-sandbox-service/
├── mis-notification-service/
├── mis-reporting-service/
├── mis-document-service/
├── mis-admin-service/
├── mis-web-frontend/
└── (optional) mis-pkg-*/        ← only if you're actively editing a package
```

The root Makefile in `mis-dev/` walks `../mis-*-service/` directories and calls each service's own Makefile. Every service Makefile exposes the same vocabulary (`make install`, `make dev`, `make test`, `make prisma-migrate`, etc.), so the root Makefile remains simple.

## 2. Prerequisites

| Tool | Version |
|------|---------|
| Node.js | LTS (20.x+) |
| npm | 10.x+ |
| Docker / Docker Compose v2 | 24.x+ |
| GNU Make | 4.x |
| `az` CLI (Azure DevOps extension) | latest |
| `kubectl` | 1.29+ |
| `helm` | 3.13+ |
| `vsts-npm-auth` | latest (`npm i -g vsts-npm-auth`) |

Minimum machine: 4 cores, 16 GB RAM, 30 GB free disk.

## 3. First-Time Bootstrap

```bash
mkdir -p ~/code/mis && cd ~/code/mis

# 1. Clone the orchestration repo
git clone https://dev.azure.com/<org>/MIS/_git/mis-dev
cd mis-dev

# 2. Use it to clone every service repo into sibling folders
make clone-all

# 3. Authenticate to the Azure Artifacts feed (one-time)
make auth-all

# 4. Bring up infra (PG, Mongo, Influx, Kafka, Redis, Vault dev, Kong)
make infra-up

# 5. Install + Prisma generate across services
make install-all
make prisma-generate-all

# 6. Apply Prisma migrations + seed
make prisma-deploy-all
make seed

# 7. Start all services in watch mode
make dev-all
```

Or simply: `make bootstrap` runs the whole sequence.

## 4. The Parent Folder Layout

```
mis-dev/
├── Makefile                              # Root orchestration (full file below)
├── repos.txt                             # List of service repo names
├── docker/
│   ├── docker-compose.yml                # Infra stack
│   ├── docker-compose.observability.yml  # Optional Prom/Grafana/Jaeger
│   ├── kong/
│   │   └── kong.yml                      # Local declarative gateway config
│   └── prometheus.yml
├── scripts/
│   ├── clone-all.sh                      # az repos clone of every entry in repos.txt
│   ├── pull-all.sh                       # git pull --rebase across all
│   ├── status-all.sh                     # git status across all
│   ├── link-packages.sh                  # Helper for local @mis/* linking
│   ├── seed.ts                           # Cross-service seed data
│   └── kafka-init.sh                     # Topic creation
├── .env.example
└── README.md
```

`repos.txt`:

```
mis-auth-service
mis-registration-service
mis-case-service
mis-sandbox-service
mis-notification-service
mis-reporting-service
mis-document-service
mis-admin-service
mis-web-frontend
```

## 5. Root Makefile (`mis-dev/Makefile`)

```makefile
# mis-dev/Makefile
SHELL          := /bin/bash
PARENT         := $(realpath ..)
REPOS_FILE     := repos.txt
SERVICES       := $(shell cat $(REPOS_FILE))
COMPOSE        := docker compose -f docker/docker-compose.yml
COMPOSE_OBS    := $(COMPOSE) -f docker/docker-compose.observability.yml

.PHONY: help bootstrap clone-all pull-all status-all auth-all \
        install-all prisma-generate-all prisma-deploy-all seed \
        infra-up infra-down infra-logs observability-up observability-down \
        dev-all dev test-all lint-all build-all clean-all \
        kafka-init kong-reload reset

# ── Help ────────────────────────────────────────────────
help:                  ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-25s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ── One-shot bootstrap ─────────────────────────────────
bootstrap: clone-all auth-all infra-up install-all \
           prisma-generate-all prisma-deploy-all kafka-init seed ## Full first-time setup

# ── Repo orchestration ─────────────────────────────────
clone-all:             ## Clone every service repo as a sibling of mis-dev/
	./scripts/clone-all.sh

pull-all:              ## git pull --rebase across all repos
	./scripts/pull-all.sh

status-all:            ## git status across all repos
	./scripts/status-all.sh

auth-all:              ## Authenticate every repo to Azure Artifacts
	@for s in $(SERVICES); do \
	  echo "→ auth $$s"; \
	  $(MAKE) -C $(PARENT)/$$s auth || true; \
	done

# ── Infrastructure (Docker Compose) ────────────────────
infra-up:              ## Start infra containers
	$(COMPOSE) up -d

infra-down:            ## Stop infra containers (keep volumes)
	$(COMPOSE) down

infra-logs:            ## Tail infra logs
	$(COMPOSE) logs -f

kafka-init:            ## Create Kafka topics
	./scripts/kafka-init.sh

kong-reload:           ## Reload Kong declarative config
	curl -s -X POST http://localhost:8001/config \
	  -F config=@docker/kong/kong.yml

observability-up:      ## Start Prometheus, Grafana, Jaeger
	$(COMPOSE_OBS) up -d prometheus grafana jaeger

observability-down:
	$(COMPOSE_OBS) stop prometheus grafana jaeger

# ── Fan-out commands across services ───────────────────
install-all:           ## Install deps in every service
	@for s in $(SERVICES); do \
	  echo "→ install $$s"; \
	  $(MAKE) -C $(PARENT)/$$s install; \
	done

prisma-generate-all:   ## Run prisma generate in every service
	@for s in $(SERVICES); do \
	  echo "→ prisma generate $$s"; \
	  $(MAKE) -C $(PARENT)/$$s prisma-generate 2>/dev/null || echo "  (skip: no prisma target)"; \
	done

prisma-deploy-all:     ## Apply pending Prisma migrations across services
	@for s in $(SERVICES); do \
	  echo "→ prisma deploy $$s"; \
	  $(MAKE) -C $(PARENT)/$$s prisma-deploy 2>/dev/null || echo "  (skip)"; \
	done

build-all:             ## Compile every service
	@for s in $(SERVICES); do \
	  echo "→ build $$s"; \
	  $(MAKE) -C $(PARENT)/$$s build; \
	done

test-all:              ## Run tests across every service
	@for s in $(SERVICES); do \
	  echo "→ test $$s"; \
	  $(MAKE) -C $(PARENT)/$$s test; \
	done

lint-all:              ## Lint every service
	@for s in $(SERVICES); do \
	  echo "→ lint $$s"; \
	  $(MAKE) -C $(PARENT)/$$s lint; \
	done

dev-all:               ## Run every service in watch mode (uses tmux)
	./scripts/dev-all.sh

dev:                   ## Run a single service in watch mode: make dev s=auth
	@test -n "$(s)" || (echo "Usage: make dev s=auth"; exit 1)
	$(MAKE) -C $(PARENT)/mis-$(s)-service dev

seed:                  ## Seed databases (cross-service)
	ts-node scripts/seed.ts

clean-all:             ## Remove dist + node_modules everywhere
	@for s in $(SERVICES); do \
	  echo "→ clean $$s"; \
	  $(MAKE) -C $(PARENT)/$$s clean || true; \
	done

reset:                 ## Nuke containers + volumes + reseed
	$(COMPOSE) down -v
	$(MAKE) bootstrap
```

`scripts/clone-all.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ORG="${AZ_ORG:?set AZ_ORG=https://dev.azure.com/<org>}"
PROJECT="${AZ_PROJECT:-MIS}"
PARENT="$(realpath "$(dirname "$0")/../..")"

while read -r repo; do
  [ -z "$repo" ] && continue
  if [ -d "$PARENT/$repo" ]; then
    echo "✓ $repo already cloned"
  else
    echo "→ cloning $repo into $PARENT/$repo"
    az repos clone --organization "$ORG" --project "$PROJECT" \
      --repository "$repo" --target "$PARENT/$repo"
  fi
done < "$(dirname "$0")/../repos.txt"
```

`scripts/dev-all.sh` opens a tmux window per service (or you can use 8 terminals):

```bash
#!/usr/bin/env bash
SESSION=mis
PARENT="$(realpath "$(dirname "$0")/../..")"

tmux new-session -d -s "$SESSION" -n auth         "cd $PARENT/mis-auth-service && make dev"
tmux new-window  -t "$SESSION"   -n registration  "cd $PARENT/mis-registration-service && make dev"
tmux new-window  -t "$SESSION"   -n case          "cd $PARENT/mis-case-service && make dev"
tmux new-window  -t "$SESSION"   -n sandbox       "cd $PARENT/mis-sandbox-service && make dev"
tmux new-window  -t "$SESSION"   -n notification  "cd $PARENT/mis-notification-service && make dev"
tmux new-window  -t "$SESSION"   -n reporting     "cd $PARENT/mis-reporting-service && make dev"
tmux new-window  -t "$SESSION"   -n document      "cd $PARENT/mis-document-service && make dev"
tmux new-window  -t "$SESSION"   -n admin         "cd $PARENT/mis-admin-service && make dev"
tmux attach     -t "$SESSION"
```

## 6. Docker Compose Stack

```yaml
# mis-dev/docker/docker-compose.yml (abbreviated)
version: "3.9"

services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_USER: mis
      POSTGRES_PASSWORD: mis
      POSTGRES_DB: mis_dev
    ports: ["5432:5432"]
    volumes: [pgdata:/var/lib/postgresql/data]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U mis"]
      interval: 5s

  mongo:
    image: mongo:7
    command: ["--replSet", "rs0", "--bind_ip_all"]
    ports: ["27017:27017"]
    volumes: [mongodata:/data/db]

  mongo-init:
    image: mongo:7
    depends_on: [mongo]
    restart: "no"
    entrypoint: >
      bash -c "sleep 5 && mongosh --host mongo:27017 --eval
      'try { rs.status() } catch (e) { rs.initiate({ _id: \"rs0\",
      members: [{ _id: 0, host: \"mongo:27017\" }] }) }'"

  influxdb:
    image: influxdb:2.7
    environment:
      DOCKER_INFLUXDB_INIT_MODE: setup
      DOCKER_INFLUXDB_INIT_USERNAME: mis
      DOCKER_INFLUXDB_INIT_PASSWORD: mis-dev-pw
      DOCKER_INFLUXDB_INIT_ORG: mis
      DOCKER_INFLUXDB_INIT_BUCKET: mis_metrics_raw
      DOCKER_INFLUXDB_INIT_ADMIN_TOKEN: dev-influx-token
    ports: ["8086:8086"]

  redis:
    image: redis:7-alpine
    ports: ["6379:6379"]

  zookeeper:
    image: confluentinc/cp-zookeeper:7.5.0
    environment: { ZOOKEEPER_CLIENT_PORT: 2181 }

  kafka:
    image: confluentinc/cp-kafka:7.5.0
    depends_on: [zookeeper]
    environment:
      KAFKA_BROKER_ID: 1
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka:9092,PLAINTEXT_HOST://localhost:29092
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,PLAINTEXT_HOST:PLAINTEXT
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
    ports: ["29092:29092"]

  vault:
    image: hashicorp/vault:1.15
    cap_add: [IPC_LOCK]
    environment:
      VAULT_DEV_ROOT_TOKEN_ID: dev-root
      VAULT_DEV_LISTEN_ADDRESS: 0.0.0.0:8200
    ports: ["8200:8200"]

  kong:
    image: kong:3.5
    environment:
      KONG_DATABASE: "off"
      KONG_DECLARATIVE_CONFIG: /kong/kong.yml
      KONG_PROXY_LISTEN: 0.0.0.0:8000
      KONG_ADMIN_LISTEN: 0.0.0.0:8001
    volumes:
      - ./kong/kong.yml:/kong/kong.yml:ro
    ports: ["8000:8000", "8001:8001"]

volumes:
  pgdata:
  mongodata:
```

Observability stack in a separate file, brought up only on demand:

```bash
make observability-up
```

## 7. Per-Service Workflow

Each service repo is independently usable; you don't need `mis-dev` to work on a single service.

```bash
cd ~/code/mis/mis-case-service
make help                        # lists targets
make install                     # auth + npm ci
make prisma-generate
make dev                         # nest start --watch
```

The service expects infra to be running. Either:

- Use `mis-dev`'s Compose stack (`cd ../mis-dev && make infra-up`), or
- Run only the bits you need (`docker run postgres ...`).

## 8. Environment Variables

Each service has `.env.example`. Local defaults match the Compose stack:

```env
# mis-case-service/.env.example
NODE_ENV=development
PORT=3003

DATABASE_URL=postgresql://mis:mis@localhost:5432/mis_case?schema=public
DIRECT_DATABASE_URL=postgresql://mis:mis@localhost:5432/mis_case?schema=public
REDIS_URL=redis://localhost:6379
KAFKA_BROKERS=localhost:29092

AUTH_JWKS_URI=http://localhost:3001/.well-known/jwks.json

VAULT_ADDR=http://localhost:8200
VAULT_TOKEN=dev-root

LOG_LEVEL=debug
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
```

Production values come exclusively from Vault. Compose-mode Vault is dev-mode with a fixed root token; **never** use this configuration anywhere other than a developer machine.

## 9. Seed Data

`mis-dev/scripts/seed.ts` calls each service's own seed script (which uses Prisma):

| Entity | Count | Notes |
|--------|------:|-------|
| Users | 20 | All roles represented; password `dev1234` |
| Applications | 50 | Mix of statuses |
| Cases | 30 | Some with SLAs near breach for testing |
| Documents | 100 | With versions, owned by various users |
| Audit events | 200 | Pre-populated for dashboard testing |

```bash
make seed                # all services
# or per-service:
cd ../mis-case-service && make seed
```

## 10. Debugging

### VS Code multi-root workspace

A workspace file that opens every service in one window:

```json
{
  "folders": [
    { "path": "mis-dev" },
    { "path": "mis-auth-service" },
    { "path": "mis-registration-service" },
    { "path": "mis-case-service" },
    { "path": "mis-sandbox-service" },
    { "path": "mis-notification-service" },
    { "path": "mis-reporting-service" },
    { "path": "mis-document-service" },
    { "path": "mis-admin-service" }
  ]
}
```

Each service repo carries a `.vscode/launch.json` with a `Debug This Service` config wired to `nest start --debug --watch`.

### Local URLs

| UI | URL |
|----|-----|
| Kong proxy | http://localhost:8000 (→ `/api/<service>` routes) |
| Kong admin | http://localhost:8001 |
| Jaeger | http://localhost:16686 |
| Grafana | http://localhost:3000 (admin/admin) |
| Prometheus | http://localhost:9090 |
| Vault UI | http://localhost:8200 (token: `dev-root`) |
| InfluxDB | http://localhost:8086 |

## 11. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `npm install` fails with 401 | Azure Artifacts token expired | `make auth` in the repo |
| `ECONNREFUSED 5432` | Postgres not ready yet | Wait 10 s, or `make infra-logs` |
| Prisma "Can't reach database server" | DB up but URL wrong | Check `.env` `DATABASE_URL` against Compose ports |
| Prisma migrate fails with "prepared statement…" | pgBouncer issue | Use `DIRECT_DATABASE_URL` for migrations, add `?pgbouncer=true` to runtime URL |
| Kafka topic missing | Topics not initialized | `make kafka-init` |
| 401 from Kong | JWT expired or wrong issuer | Re-login via Auth, check `.env` JWKS URL |
| `EADDRINUSE :3003` | Service already running on host | `lsof -i :3003` then kill |
| `@mis/*` package not found | Feed auth missing | `make auth-all` |
| Mongo replica set not initiated | `mongo-init` race | `docker compose restart mongo-init` |
