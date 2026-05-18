# mis-dev — local orchestration

Root Makefile + Docker Compose for the MIS PoC.

## Prerequisites

Install / have available before anything else:

| Need | Why | Check |
|------|-----|-------|
| Docker Engine + Compose v2 | infra + (optional) service containers | `docker compose version` |
| Node.js ≥ 20 + npm | workspaces, host-mode dev, building `@mis/*` | `node -v` |
| `bash`, `curl`, `openssl` | `mint-token.sh`, verification | `openssl version` |
| `tmux` *(optional)* | only for `make dev-all` | `tmux -V` |

**Free host ports** (a leftover Compose project or stray `node` squatting
these is the #1 failure — stop it first):

- `3001–3008` — the 8 services
- `5432 / 27017 / 6379 / 29092` — Postgres / Mongo / Redis / Kafka
- `8000 / 8001 / 8100` — Kong proxy / admin / status(+metrics)

**One-time setup** (from the monorepo root, the parent of `mis-dev/`):

```bash
npm install            # links the 8 services + 8 @mis/* packages via workspaces
npm run build:pkgs     # compile @mis/* to dist/ (services import the built output)
```

All `make` targets below are run from `mis-dev/`. `make help` lists them all.

## TL;DR

```bash
# from the monorepo root
npm install            # links everything via workspaces
cd mis-dev
make infra-up          # bring up Postgres / Mongo / Redis / Kafka / Kong
make dev s=auth        # run one service (or `make dev-all` for tmux)

curl http://localhost:3001/health
curl http://localhost:8000/api/auth/health   # same response via Kong
```

`make help` lists every target.

## How the flow works

Two independent Docker Compose projects + your code:

- **`mis-dev`** — infra: Postgres, Mongo, Redis, Kafka, **Kong**. Started by
  `make infra-up` (also auto-creates Kafka topics).
- **`mis-services`** — the 8 NestJS services *as containers* (optional —
  `docker/services.yml`). Started by `make services-up`. Or skip it and run
  services on the **host** with `make dev`.

Either way the services publish ports `3001–3008`, and Kong reaches them via
`host.docker.internal` — so **how** you run the services never requires a
Kong change.

A request travels:

```
client ──▶ Kong :8000 ──────────────────────────────────────▶ service :300x
            │  /api/<domain>                                    │
            │  ├─ correlation-id : add/propagate X-Correlation-ID
            │  ├─ rate-limiting  : 120/min per IP → 429 if over
            │  ├─ jwt            : verify HS256 + exp → 401 if bad/missing
            │  └─ (auth-public routes skip jwt)                  │
            │                                                    ▼
            │                              @mis/auth-middleware reads the
            │                              forwarded claims + correlation id
            │                              → req.user / req.correlationId
            │                              @mis/access-control: can()/hasRole()
            ▼
        :8100/metrics  (Prometheus: requests, latency, status codes)
```

Kong proves **who** the caller is (authN) at the edge; services decide
**what** they may do (authZ) internally. Health/readiness probes hit the
service ports directly and bypass the gateway.

### The setup-to-request flow

```bash
# 0. one-time (monorepo root)
npm install && npm run build:pkgs

# 1. infra (Kong + datastores + Kafka topics)
cd mis-dev && make infra-up

# 2. run the services — pick ONE:
make dev s=auth          # host, watch mode (fast iteration); or `make dev-all`
#   …or…
make images-build        # build all 8 images from local code
make services-up         #   then run them from those images

#   …or the one-shot equivalent of 1+2 (containers):
make stack-up            # infra (+topics) + all services from existing images

# 3. call through the gateway
TOKEN=$(./scripts/mint-token.sh)                          # or: make kong-token
curl localhost:8000/api/auth/login                        # 200 — public route
curl localhost:8000/api/auth/                             # 401 — needs a token
curl -H "Authorization: Bearer $TOKEN" localhost:8000/api/auth/   # 200

# 4. observe / stop
make urls   make kong-metrics                             # cheat-sheet, metrics
make stack-down            # stop everything   (or infra-down / services-down)
```

When you change `@mis/*` code: host mode picks it up automatically; container
mode needs `make images-build` again. When you change `docker/kong/kong.yml`:
`make kong-reload` (no restart). Details for each path below.

## Running locally

All commands run from `mis-dev/`. Infra runs in Docker; the NestJS
services run on the host.

```bash
# 1. one-time: install + build the @mis/* packages (from monorepo root)
npm install && npm run build:pkgs

# 2. start infra (Postgres/Mongo/Redis/Kafka/Kong + auto-creates Kafka topics)
make infra-up

# 3. start service(s) on the host
make dev s=auth        # one service in watch mode → :3001
make dev-all           # all 8 in watch mode (needs tmux)

# 4. verify
make urls                                  # URL cheat-sheet
curl localhost:3001/health                 # direct
curl localhost:8000/api/auth/health        # via Kong proxy

# 5. stop
make infra-down        # stop infra (volumes kept); Ctrl-C stops `make dev`
```

## Running the services in Docker (instead of on the host)

For testing local changes across all services at once — build every image,
then run from the built images without rebuilding. Defined in
`docker/services.yml` (a separate `mis-services` Compose project) with image
refs read from `docker/.env` (copy `docker/.env.example`), so tags/registry
are never hardcoded.

```bash
make images-build        # build Docker images for ALL 8 services from local code
make images-build s=auth # …or just one

make services-up         # run ALL services from the EXISTING images (no rebuild)
make services-up s=auth  # …or just one
make services-ps         # status   |   make services-logs [s=auth]
make services-down       # stop & remove the service containers

make stack-up            # one shot: infra (+Kafka topics) + all services
make stack-down          # stop everything
```

Services publish ports 3001–3008, so Kong's existing upstreams keep working
— **no `kong.yml` edit and no Kong restart** when you rebuild/redeploy a
service. The `mis-services` and `mis-dev` (infra) Compose projects have
independent lifecycles: `services-up/down` never touches Kong or the infra.

Workflow when iterating on code: `make images-build [s=…]` then
`make services-up`. `services-up` won't rebuild (`--no-build`) — if an
image is missing it errors instead of pulling, so build first.

`s=` accepts: `auth registration case sandbox notification reporting
document admin` (ports 3001–3008). Kong returns `502` for a domain whose
host service isn't running. First `make infra-up` waits up to ~90s for the
Kafka broker before creating topics — that pause is expected.

## Gateway (Kong) — auth, rate limiting, metrics, correlation id

Cross-cutting concerns are handled at the gateway, not duplicated in every
service (`docker/kong/kong.yml`):

| Plugin | Scope | Effect |
|--------|-------|--------|
| `jwt` | every `<svc>` route (not `<svc>-public`) | HS256 token + `exp` required; rejected at the edge with 401 |
| `rate-limiting` | global | 120 req/min per client IP (local policy) |
| `prometheus` | global | metrics at `http://localhost:8100/metrics` |
| `correlation-id` | global | injects/propagates `X-Correlation-ID` (client value passes through) |

### Whitelisting endpoints

`strip_path` is **off** everywhere — each NestJS service owns its real
`/api/<domain>` path (`app.setGlobalPrefix`). Every service has two Kong
routes:

- `<svc>` → path `/api/<domain>`, **has** the `jwt` plugin (protected)
- `<svc>-public` → specific paths, **no** `jwt` (whitelisted)

Kong matches the longest path first, so `*-public` paths win and skip auth.
**To whitelist an endpoint, add its full path to that service's
`<svc>-public` route in `docker/kong/kong.yml`** and `make kong-reload`.
Currently whitelisted: every `…/health` & `…/ready`, plus `/api/auth/login`.

### Auth & authorization

Services don't re-authenticate. They use `@mis/auth-middleware`
(`gatewayIdentity()` → `req.user` / `req.correlationId` from the forwarded
JWT) and `@mis/access-control` (5 permissions, 2 roles, `accessGuard()`,
`can()`, `permissionsForRoles()`) for **authZ only** — Kong proves *who*,
each service decides *what* via a required permission.

| Role | Permissions | Can use |
|------|-------------|---------|
| `case-officer` | `case:read` `case:write` `profile:read` | Case service |
| `reporting-analyst` | `reporting:read` `reporting:export` `profile:read` | Reporting service |

Two hardcoded test users (`mis-auth-service/src/users.ts`):

| Login (username or email) | Password | Role |
|---|---|---|
| `caseofficer` / `case.officer@mis.local` | `case123` | `case-officer` |
| `reportanalyst` / `report.analyst@mis.local` | `report123` | `reporting-analyst` |

```bash
G=localhost:8000
# log in (whitelisted) — returns { access_token, ... }
TOKEN=$(curl -s -X POST $G/api/auth/login -H 'content-type: application/json' \
  -d '{"usernameOrEmail":"caseofficer","password":"case123"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

curl $G/api/cases/health                                  # 200 — whitelisted
curl $G/api/cases/                                        # 401 — no token (Kong)
curl -H "Authorization: Bearer $TOKEN" $G/api/cases/      # 200 — case-officer ok
curl -H "Authorization: Bearer $TOKEN" $G/api/reporting/  # 403 — wrong permission
curl -H "Authorization: Bearer $TOKEN" $G/api/cases/me    # roles + permissions
make kong-metrics                                         # Kong Prometheus counters
```

`make kong-token` still mints a generic admin token (bypasses login) for
quick checks; `GET /api/<domain>/me` on any service returns the caller's
identity, roles and resolved permissions.

The signing secret is a throwaway dev value duplicated in `kong.yml` and
`scripts/mint-token.sh` (`JWT_SECRET`, default `mis-poc-dev-secret-change-me`)
— Kong's `jwt_secrets.secret` isn't vault-referenceable, so wire a real
secret store before anything non-local. After editing `kong.yml`, apply it
with `make kong-reload` (DB-less hot reload, no restart).

## What's in `docker/`

| Service | Port(s) | Notes |
|---------|---------|-------|
| Postgres 16 | 5432 | user/pass/db = `mis` / `mis` / `mis_dev` |
| Mongo 7 (single-node RS) | 27017 | `rs0` initiated by `mongo-init` |
| Redis 7 | 6379 | |
| Zookeeper + Kafka | 29092 (host) | `localhost:29092` from host, `kafka:9092` in-network |
| Kong 3.5 (DB-less) | 8000 proxy, 8001 admin, 8100 status | routes `/api/<domain>` → host services; jwt/rate-limit/prometheus/correlation-id; `/metrics` on 8100 |

Kong uses `host.docker.internal` to reach services running on the host. On Linux that hostname is mapped via `extra_hosts: host-gateway`. If you run services inside Compose too, replace `host.docker.internal` with the service name in `docker/kong/kong.yml`.

## Adding real persistence later

Each service Makefile already exposes `prisma-generate`, `prisma-migrate`, `prisma-deploy`, and `seed` targets — they are stubs today. When you drop a `prisma/schema.prisma` into a service, replace the stub with real `npx prisma …` invocations and the root `make prisma-deploy-all` will pick it up automatically.
