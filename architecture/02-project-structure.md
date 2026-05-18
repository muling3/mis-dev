# 02 — Project Structure (Multi-Repo)

## Table of Contents

1. [Repository Strategy](#1-repository-strategy)
2. [Azure DevOps Org Layout](#2-azure-devops-org-layout)
3. [Per-Service Repository Structure](#3-per-service-repository-structure)
4. [Per-Service Makefile](#4-per-service-makefile)
5. [Shared Package Repository Structure](#5-shared-package-repository-structure)
6. [Per-Package Makefile](#6-per-package-makefile)
7. [`mis-proto` Repository](#7-mis-proto-repository)
8. [`mis-config` Repository](#8-mis-config-repository)
9. [`mis-dev` — Local Parent Folder](#9-mis-dev--local-parent-folder)
10. [Naming Conventions](#10-naming-conventions)

---

## 1. Repository Strategy

Each microservice, each shared package, and each cross-cutting concern lives in **its own Azure DevOps Git repository**. This gives:

- Independent change history per component
- Smaller, focused PRs — no cross-service merge conflicts
- Per-repo CODEOWNERS and branch policies
- True affected-only CI — only the repo that changed runs a pipeline
- Per-repo RBAC in Azure DevOps Repos

The trade-off is that local development needs an orchestration layer; that's what `mis-dev` and the root `Makefile` provide.

## 2. Azure DevOps Org Layout

```
Org:  dev.azure.com/<your-org>
└── Project: MIS
    ├── Repos (one per component)
    │   ├── mis-auth-service
    │   ├── mis-registration-service
    │   ├── mis-case-service
    │   ├── mis-sandbox-service
    │   ├── mis-notification-service
    │   ├── mis-reporting-service
    │   ├── mis-document-service
    │   ├── mis-admin-service
    │   ├── mis-web-frontend
    │   ├── mis-pkg-auth-middleware
    │   ├── mis-pkg-audit-logger
    │   ├── mis-pkg-error-formatter
    │   ├── mis-pkg-metrics
    │   ├── mis-pkg-access-control
    │   ├── mis-pkg-validation-schemas
    │   ├── mis-pkg-circuit-breaker
    │   ├── mis-proto
    │   ├── mis-config
    │   └── mis-dev
    ├── Pipelines (one per repo, plus shared templates)
    │   └── pipeline-templates/                # shared YAML templates
    ├── Artifacts
    │   ├── mis-npm        (npm-compatible feed for @mis/*)
    │   └── mis-proto      (versioned proto bundle)
    └── Boards (work items / epics)
```

The shared pipeline templates repo holds the standard build/test/scan/publish steps so every service or package YAML pipeline is a thin wrapper that includes the template. This keeps cross-cutting CI changes to a single PR. See [10 — CI/CD](./10-cicd-pipeline.md).

## 3. Per-Service Repository Structure

Every service repo (e.g. `mis-case-service`) follows the same structure so engineers can move between services without re-learning layout.

```
mis-case-service/
├── src/
│   ├── main.ts                            # Bootstrap
│   ├── app.module.ts
│   ├── config/
│   │   ├── configuration.ts
│   │   ├── vault.ts
│   │   └── validation.ts                  # Zod schema for env vars
│   ├── modules/
│   │   ├── cases/
│   │   │   ├── cases.controller.ts
│   │   │   ├── cases.service.ts
│   │   │   ├── cases.module.ts
│   │   │   ├── dto/
│   │   │   └── __tests__/
│   │   ├── assignments/
│   │   ├── sla/
│   │   └── escalations/
│   ├── common/
│   │   ├── filters/
│   │   ├── interceptors/
│   │   ├── guards/
│   │   └── decorators/
│   ├── infrastructure/
│   │   ├── prisma/
│   │   │   └── prisma.service.ts          # PrismaClient wrapper, lifecycle hooks
│   │   ├── kafka/
│   │   ├── redis/
│   │   └── grpc/
│   ├── events/
│   │   ├── producers/
│   │   └── consumers/
│   └── health/
│       ├── health.controller.ts
│       └── readiness.controller.ts
├── prisma/
│   ├── schema.prisma                      # Prisma schema (Postgres provider)
│   └── migrations/                        # Prisma migrations
├── test/
│   ├── e2e/
│   └── integration/
├── Dockerfile
├── .dockerignore
├── .env.example
├── .npmrc                                 # Points to Azure Artifacts feed
├── nest-cli.json
├── tsconfig.json
├── tsconfig.build.json
├── jest.config.ts
├── package.json
├── package-lock.json
├── Makefile                               # Service-level commands
├── azure-pipelines.yml                    # CI pipeline
├── CODEOWNERS
└── README.md
```

### Service domain modules

| Service | Domains under `src/modules/` |
|---------|-------------------------------|
| `mis-auth-service` | `users`, `sessions`, `mfa`, `tokens`, `password-reset` |
| `mis-registration-service` | `applications`, `certificates`, `registry`, `renewals` |
| `mis-case-service` | `cases`, `assignments`, `sla`, `escalations`, `attachments` |
| `mis-sandbox-service` | `submissions`, `scanners`, `quarantine`, `verdicts` |
| `mis-notification-service` | `email`, `sms`, `websocket`, `templates`, `subscriptions` |
| `mis-reporting-service` | `dashboards`, `exports`, `metrics`, `aggregations` |
| `mis-document-service` | `documents`, `versions`, `storage`, `access` |
| `mis-admin-service` | `audit`, `users-admin`, `system-config`, `dlq-alerts` |

### `.npmrc` template

Every service and the frontend ship with an `.npmrc` pointing at the Azure Artifacts feed for `@mis/*` packages:

```ini
@mis:registry=https://pkgs.dev.azure.com/<org>/MIS/_packaging/mis-npm/npm/registry/
always-auth=true
```

Authentication is handled by:
- Locally: `npm install -g vsts-npm-auth && vsts-npm-auth -config .npmrc`
- In CI: the Azure Pipelines `npmAuthenticate` task

## 4. Per-Service Makefile

Every service exposes the same Make vocabulary. This is the contract — the root `mis-dev/Makefile` relies on it.

```makefile
# mis-case-service/Makefile
SERVICE      := case-service
IMAGE        := mis/$(SERVICE)
REGISTRY     ?= misregistry.azurecr.io
TAG          ?= $(shell git rev-parse --short HEAD)
NODE_ENV     ?= development

.PHONY: help install auth dev build test test-int lint typecheck \
        docker-build docker-push prisma-generate prisma-migrate \
        prisma-deploy prisma-studio seed clean

help:                  ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

install:               ## Install dependencies (auth to feed first)
	npx vsts-npm-auth -config .npmrc || true
	npm ci

auth:                  ## Re-auth to Azure Artifacts feed
	npx vsts-npm-auth -config .npmrc

dev:                   ## Run service in watch mode
	npm run start:dev

build:                 ## Compile TypeScript
	npm run build

test:                  ## Unit tests
	npm test

test-int:              ## Integration tests (requires infra up)
	npm run test:integration

lint:                  ## ESLint + Prettier check
	npm run lint

typecheck:             ## tsc --noEmit
	npm run typecheck

prisma-generate:       ## Generate Prisma client
	npx prisma generate

prisma-migrate:        ## Create + apply a new dev migration
	npx prisma migrate dev

prisma-deploy:         ## Apply migrations in non-dev environments
	npx prisma migrate deploy

prisma-studio:         ## Open Prisma Studio
	npx prisma studio

seed:                  ## Seed local DB
	npm run seed

docker-build:          ## Build Docker image
	docker build -t $(REGISTRY)/$(IMAGE):$(TAG) .

docker-push:           ## Push to registry
	docker push $(REGISTRY)/$(IMAGE):$(TAG)

clean:                 ## Remove build artifacts
	rm -rf dist node_modules
```

Every other service uses an identical Makefile, differing only in `SERVICE`.

## 5. Shared Package Repository Structure

Every `@mis/*` package lives in its own repo (e.g. `mis-pkg-circuit-breaker`).

```
mis-pkg-circuit-breaker/
├── src/
│   ├── index.ts                           # Public API barrel
│   ├── client.ts
│   ├── config.ts
│   └── __tests__/
├── dist/                                  # build output (gitignored)
├── .npmrc                                 # Azure Artifacts feed
├── package.json                           # name: "@mis/circuit-breaker"
├── package-lock.json
├── tsconfig.json
├── jest.config.ts
├── Makefile
├── azure-pipelines.yml                    # build, pack, publish
├── CHANGELOG.md
├── CODEOWNERS
└── README.md
```

### `package.json` highlights

```json
{
  "name": "@mis/circuit-breaker",
  "version": "1.4.2",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "publishConfig": {
    "registry": "https://pkgs.dev.azure.com/<org>/MIS/_packaging/mis-npm/npm/registry/"
  },
  "files": ["dist", "README.md", "CHANGELOG.md"],
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "test": "jest",
    "lint": "eslint src"
  }
}
```

## 6. Per-Package Makefile

```makefile
# mis-pkg-circuit-breaker/Makefile
PACKAGE := @mis/circuit-breaker
VERSION ?= $(shell node -p "require('./package.json').version")

.PHONY: help install auth build test lint pack publish version-patch \
        version-minor version-major clean

help:                  ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

install:               ## Install dev dependencies
	npx vsts-npm-auth -config .npmrc || true
	npm ci

auth:                  ## Re-auth to Azure Artifacts feed
	npx vsts-npm-auth -config .npmrc

build:                 ## Compile to dist/
	rm -rf dist
	npx tsc -p tsconfig.json

test:                  ## Run tests
	npm test

lint:                  ## ESLint check
	npm run lint

pack:                  ## Build then npm pack (tarball preview)
	$(MAKE) build
	npm pack

version-patch:         ## Bump patch (1.4.2 -> 1.4.3)
	npm version patch -m "chore(release): %s"

version-minor:         ## Bump minor (1.4.2 -> 1.5.0)
	npm version minor -m "chore(release): %s"

version-major:         ## Bump major (1.4.2 -> 2.0.0)
	npm version major -m "chore(release): %s"

publish:               ## Publish to Azure Artifacts feed
	$(MAKE) build
	npm publish

clean:                 ## Remove artefacts
	rm -rf dist node_modules *.tgz
```

The CI pipeline calls `make publish` after merging a release-tagged commit. Local publish is possible but reserved for emergencies.

## 7. `mis-proto` Repository

Holds the canonical gRPC Protocol Buffer definitions. Packaged as `@mis/proto` and consumed by the Auth and Sandbox services (and their callers).

```
mis-proto/
├── proto/
│   ├── auth.proto
│   └── sandbox.proto
├── src/
│   └── index.ts                           # Re-exports generated types
├── generated/                             # protoc output (gitignored)
├── scripts/
│   └── generate.sh                        # Runs protoc
├── package.json                           # name: "@mis/proto"
├── tsconfig.json
├── Makefile
├── azure-pipelines.yml
└── README.md
```

```makefile
# mis-proto/Makefile
.PHONY: generate build pack publish

generate:              ## Run protoc and emit TS types
	./scripts/generate.sh

build:                 ## Generate + compile
	$(MAKE) generate
	npx tsc

publish:               ## Publish @mis/proto to Azure Artifacts
	$(MAKE) build
	npm publish
```

## 8. `mis-config` Repository

ArgoCD's source of truth.

```
mis-config/
├── argocd/
│   ├── applications/
│   │   ├── auth-service.yaml
│   │   ├── registration-service.yaml
│   │   └── ...
│   └── projects/
│       └── mis.yaml
├── helm/
│   ├── auth-service/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   ├── values-production.yaml
│   │   ├── values-staging.yaml
│   │   └── templates/
│   ├── registration-service/
│   ├── ...
│   └── _shared/                           # Common library chart
├── kong/
│   ├── kong.yaml                          # Declarative routes + plugins
│   └── consumers/
├── kubernetes/
│   ├── namespaces/
│   ├── networkpolicies/
│   ├── rbac/
│   └── storage-classes/
├── terraform/
│   ├── modules/
│   ├── environments/
│   └── backend.tf
├── ansible/
│   ├── inventories/
│   ├── roles/
│   └── playbooks/
├── runbooks/
├── Makefile                               # validate, lint, dry-run helm
└── azure-pipelines.yml
```

```makefile
# mis-config/Makefile
.PHONY: lint helm-lint kube-validate terraform-fmt all

lint:                  ## Validate YAML
	yamllint .

helm-lint:             ## Lint all charts
	@for c in helm/*/; do echo "→ $$c"; helm lint $$c; done

kube-validate:         ## Validate K8s manifests
	@for c in helm/*/; do helm template $$c | kubeval --strict; done

terraform-fmt:         ## Terraform fmt check
	terraform -chdir=terraform fmt -check -recursive

all: lint helm-lint kube-validate terraform-fmt
```

## 9. `mis-dev` — Local Parent Folder

A small repo whose sole job is to orchestrate local development across all the per-service repos cloned side by side.

```
mis-dev/
├── Makefile                               # Master orchestration
├── docker/
│   ├── docker-compose.yml                 # Infra: PG, Mongo, Influx, Kafka, Redis, Vault, Kong
│   ├── docker-compose.observability.yml   # Prometheus, Grafana, Jaeger (optional)
│   └── kong/
│       └── kong.yml                       # Local declarative gateway config
├── scripts/
│   ├── clone-all.sh                       # Clones all repos
│   ├── pull-all.sh                        # git pull --rebase across all
│   ├── status-all.sh                      # git status across all
│   ├── seed.ts                            # Cross-service seed data
│   └── kafka-init.sh                      # Topic creation
├── .env.example
└── README.md
```

The expected on-disk layout once cloned:

```
~/code/mis/                                # any parent directory
├── mis-dev/                               # this repo (orchestration)
├── mis-auth-service/
├── mis-registration-service/
├── mis-case-service/
├── mis-sandbox-service/
├── mis-notification-service/
├── mis-reporting-service/
├── mis-document-service/
├── mis-admin-service/
├── mis-web-frontend/
├── mis-pkg-auth-middleware/               # only if you're working on a package locally
├── mis-pkg-...                            # ... otherwise consumed from Azure Artifacts
└── ...
```

The root Makefile loops through service repos. See [09 — Local Development](./09-local-development.md) for the full file.

## 10. Naming Conventions

| Asset | Pattern | Example |
|-------|---------|---------|
| Service repo | `mis-<domain>-service` | `mis-registration-service` |
| Package repo | `mis-pkg-<name>` | `mis-pkg-audit-logger` |
| Docker image | `<registry>/mis/<service>:<git-sha>` | `misregistry.azurecr.io/mis/auth:a3f1d2c` |
| Helm release | `<service>` in namespace | `auth` in `mis-production` |
| K8s Deployment / Service | `<service>` | `auth` |
| Kong route prefix | `/api/<domain>` | `/api/cases` |
| Kafka topic | `mis.<domain>[.<subtype>]` | `mis.cases.sla` |
| Consumer group | `<service>.<topic-domain>` | `notification.cases.sla` |
| Redis key prefix | `<service>:<entity>:<id>` | `auth:session:u-123` |
| Env var | `SCREAMING_SNAKE_CASE` | `KAFKA_BROKERS` |
| TypeScript file | `kebab-case` | `case-assignment.service.ts` |
| Database (PG) | `mis_<service>` | `mis_registration` |
| Prisma migration | `YYYYMMDDHHMMSS_description` | `20260514120000_add_sla_index` |
| `@mis/*` package | `@mis/<name>` | `@mis/circuit-breaker` |
