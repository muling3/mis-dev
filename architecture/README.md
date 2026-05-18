# MIS — Microservices Architecture Documentation

This repository contains the architectural documentation for the **MIS (Management Information System)** platform: an eight-service NestJS-based microservices system, **one Git repository per service**, deployed on a self-managed Kubernetes cluster, with strong emphasis on auditability, observability, and air-gapped sandbox isolation.

VCS and CI/CD are standardised on **Azure DevOps** (Repos + Pipelines + Artifacts).

---

## Table of Contents

| # | Document | Purpose |
|---|----------|---------|
| 01 | [Architecture Overview](./01-architecture-overview.md) | High-level system, component diagrams, request lifecycle |
| 02 | [Project Structure (multi-repo)](./02-project-structure.md) | Per-service repos, parent dev folder, Makefiles |
| 03 | [Service Communication](./03-service-communication.md) | Kafka topics, gRPC contracts, REST + circuit breaker |
| 04 | [Shared Packages](./04-shared-packages.md) | `@mis/*` via Azure Artifacts feed, Makefile publish |
| 05 | [Infrastructure & Deployment](./05-infrastructure-deployment.md) | Kubernetes, Helm, ArgoCD, Terraform, Ansible |
| 06 | [Database Architecture](./06-database-architecture.md) | PostgreSQL HA, MongoDB, InfluxDB, **Prisma ORM** |
| 07 | [Observability](./07-observability.md) | Prometheus, Grafana, Jaeger, ELK |
| 08 | [Security Architecture](./08-security.md) | JWT, Vault, NetworkPolicies, sandbox isolation |
| 09 | [Local Development](./09-local-development.md) | Parent folder + root Makefile, Docker Compose |
| 10 | [CI/CD Pipeline](./10-cicd-pipeline.md) | Azure Pipelines per repo, affected-only deploys |
| 11 | [External Integrations](./11-integrations.md) | RDB, NIDA, NPKI, NCSA HRMS, RURA, RGB, BNR, RRA, RMB, MOH, NISR — patterns, breakers, fallback |
|  — | [`schema.dbml`](./schema.dbml) | Full entity-relationship model (open in dbdiagram.io) |

---

## Repository Map

| Repo | Contents | Pipeline |
|------|----------|----------|
| `mis-auth-service` | Auth Service code + Dockerfile + Makefile + `azure-pipelines.yml` | Build, scan, push, bump |
| `mis-registration-service` | Registration Service | Same |
| `mis-case-service` | Case Service | Same |
| `mis-sandbox-service` | Sandbox Service | Same |
| `mis-notification-service` | Notification Service | Same |
| `mis-reporting-service` | Reporting Service | Same |
| `mis-document-service` | Document Service | Same |
| `mis-admin-service` | Admin Service | Same |
| `mis-web-frontend` | React SPA | Build, push, bump |
| `mis-pkg-auth-middleware` | `@mis/auth-middleware` | Build, pack, publish to Azure Artifacts |
| `mis-pkg-audit-logger` | `@mis/audit-logger` | Same |
| `mis-pkg-error-formatter` | `@mis/error-formatter` | Same |
| `mis-pkg-metrics` | `@mis/metrics` | Same |
| `mis-pkg-access-control` | `@mis/access-control` | Same |
| `mis-pkg-validation-schemas` | `@mis/validation-schemas` | Same |
| `mis-pkg-circuit-breaker` | `@mis/circuit-breaker` | Same |
| `mis-proto` | Shared `.proto` definitions for gRPC | Build, pack, publish |
| `mis-config` | Helm charts, ArgoCD apps, Kong config, Terraform, Ansible | Lint, validate, ArgoCD reconciles |
| `mis-dev` | Parent folder with root Makefile, Docker Compose, scripts for local dev | Not a deploy pipeline |

**Why multi-repo**: independent change-tracking, smaller blast radius per PR, per-service CODEOWNERS, true affected-only builds (only the repo that changed runs CI), and clean RBAC in Azure DevOps Repos.

---

## System At A Glance

```
                    ┌───────────────────────────────────────────┐
                    │              React Frontend               │
                    │             Public Portal Forms           │
                    └────────────────────┬──────────────────────┘
                                         │  HTTPS
                                         ▼
                    ┌───────────────────────────────────────────┐
                    │           Kong API Gateway (OSS)          │
                    │  JWT · Rate-Limit · Validator · OTel · Cx │
                    └────────────────────┬──────────────────────┘
                                         │
        ┌────────────┬──────────────┬────┴────┬─────────────┬─────────────┐
        ▼            ▼              ▼         ▼             ▼             ▼
   ┌────────┐  ┌────────────┐  ┌────────┐ ┌────────┐  ┌─────────────┐ ┌────────┐
   │  Auth  │  │Registration│  │  Case  │ │Sandbox │  │Notification │ │Reporting│
   └────┬───┘  └─────┬──────┘  └───┬────┘ └───┬────┘  └──────┬──────┘ └────┬───┘
        │            │             │          │              │             │
        │       ┌────▼──────┐ ┌────▼────┐ ┌───▼────┐    ┌────▼────┐  ┌─────▼────┐
        │       │ Document  │ │  Admin  │ │ AIR-GAP│    │WebSocket│  │ InfluxDB │
        │       └───────────┘ └─────────┘ │  NODE  │    └─────────┘  └──────────┘
        │                                 └────────┘
        ▼
   ┌──────────────────────────────────────────────────────────────────────┐
   │  Kafka (3 brokers) · Redis · PostgreSQL HA · MongoDB RS · Vault      │
   └──────────────────────────────────────────────────────────────────────┘
```

---

## Service Catalogue

| Service | Port | Public URL prefix (via Kong) | Primary DB | ORM |
|---------|-----:|------------------------------|-----------|-----|
| Auth | 3001 | `/api/auth` | PostgreSQL | Prisma |
| Registration | 3002 | `/api/registration` | PostgreSQL | Prisma |
| Case | 3003 | `/api/cases` | PostgreSQL | Prisma |
| Sandbox | 3004 | `/api/sandbox` | MongoDB | Prisma |
| Notification | 3005 | `/api/notifications` | PostgreSQL + Redis | Prisma |
| Reporting | 3006 | `/api/reporting` | PostgreSQL + InfluxDB | Prisma (PG only) |
| Document | 3007 | `/api/documents` | MongoDB | Prisma |
| Admin | 3008 | `/api/admin` | PostgreSQL | Prisma |

Each prefix maps in Kong to the relevant upstream service. See [03 — Service Communication](./03-service-communication.md) for the full route table.

---

## Core Design Principles

| Principle | Implementation |
|-----------|----------------|
| **One repo per service** | Clear ownership, isolated CI, affected-only deploys |
| **Sessionless services** | All state in Redis/PostgreSQL/MongoDB; any pod serves any request |
| **Single ingress** | Kong is the only public entry; backends never face the internet |
| **Replayable events** | Kafka with idempotent producers, manual offset commit |
| **Shared packages via Azure Artifacts** | Versioned, not on public npm |
| **Defence in depth** | NetworkPolicies + JWT + RBAC + Vault + air-gapped sandbox |
| **GitOps for deploys** | ArgoCD reconciles cluster from `mis-config` repo |
| **Make everywhere** | Every repo has a `Makefile` with the same vocabulary (`make build`, `make test`, `make publish`, etc.) |

---

## How to Read This Documentation

- **New engineers**: `01` → `02` → `09` (get your environment up).
- **SREs / Platform**: `05` → `07` → `08` → `10`.
- **Backend engineers**: `03` → `04` → `06`.
- **Integration engineers**: `11` → `03` → `08` (proxy + secrets).
- **Auditors**: `08` → relevant sections in `03` and `07`.

Each document is self-contained with its own table of contents and cross-links where helpful.
