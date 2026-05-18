# mis-dev — MIS local orchestration

**One git repo per service / package.** `mis-dev` is *not* a monorepo root —
it provides the shared **infra** (Postgres, Mongo, Redis, Kafka), the **Kong**
API gateway, the **architecture docs** (`architecture/`), and the **scaffold
generator**. You clone `mis-dev` once for infra, and separately clone the one
service repo you're working on.

`make help` lists every target. `make repos` lists every repo + clone URL.

## Prerequisites

| Need | Why | Check |
|------|-----|-------|
| Docker Engine + Compose v2 | infra + Kong | `docker compose version` |
| Node.js ≥ 22 (LTS) + npm | building/running a service | `node -v` |
| `bash`, `curl`, `openssl` | `mint-token.sh`, verification | `openssl version` |
| git over SSH to `github.com/muling3` | cloning service/package repos | `ssh -T git@github.com` |

**Host ports that must be free** (a stray process/Compose project here is the
#1 failure):

- `5432 / 27017 / 6379 / 29092` — Postgres / Mongo / Redis / Kafka
- `8000 / 8001 / 8100` — Kong proxy / admin / status(+metrics)
- `3001–3008` — a service runs on its own port (see `docs/urls.txt`)

## Quick start

```bash
git clone git@github.com:muling3/mis-dev.git && cd mis-dev

# Work on ONE service through Kong — clones it next to mis-dev, installs
# deps, brings up infra+Kong, runs it. No manual steps, no errors.
make dev s=auth                       # → :3001, via Kong :8000/api/auth/...

# verify
curl localhost:8000/api/auth/health   # through the gateway
make urls                             # every URL/port
```

`make dev s=<domain>` is the one-command path: it `git clone`s the service
repo into `../` if missing, runs its `install-standalone`, ensures
infra+Kong, then starts it on its port. Kong already routes
`/api/<domain>` → `http://localhost:<port>`, so it's reachable through the
gateway with no Kong change. A domain whose service isn't running → `502`.

Manual equivalent (if you prefer to drive the service repo yourself):

```bash
make infra-up                                   # infra + Kong, once
cd .. && git clone git@github.com:muling3/mis-auth-svc.git && cd mis-auth-svc
make install-standalone                          # @mis/* from GitHub (or install-azure)
make dev                                         # watch mode → :3001
```

### Lead dev — full local environment

```bash
make clone-all          # clone every service + package repo into ../
make up-all             # infra + every cloned service (background)
make down-all           # stop all services + infra
```

`clone-all` honours `REPO_URLS="git@…/a.git,git@…/b.git"` (comma-separated)
to clone a custom subset; the default is every repo in `repos.txt` except
`mis-dev`. `up-all` builds & runs each cloned service in the background
(logs in `/tmp/mis-<domain>.log`).

### Building a service image (standalone)

Each service's `Dockerfile` is **standalone** (context = that repo only). It
pulls `@mis/*` from the Azure feed using a BuildKit secret so the token never
enters a layer. In the service repo:

```bash
cp .npmrc.example .npmrc                         # set <org>/<project>/<feed>
export AZURE_NPM_TOKEN="$(printf %s '<PAT>' | base64 | tr -d '\n')"
make docker-build                                # → mis/<svc>:dev
```

## The model

```
mis-dev/            ← clone for infra + Kong + docs (this repo)
mis-auth-svc/       ← clone the ONE service you work on
mis-pkg-*/          ← shared @mis/* packages (consumed via Azure feed / git)
```

`make repos` prints all of them with clone URLs. Each repo is **independent**:
own git remote, own `.gitignore`, self-contained `tsconfig.json`
(`nodenext`/ES2023), and the standard Makefile vocabulary
(`install`, `install-standalone`, `install-azure`, `auth`, `dev`, `build`,
`start`, `test`, `lint`, `typecheck`, `docker-build`, `prisma-*`, `clean`;
packages also `pack`/`publish`).

`make scaffold` regenerates the *entire* set of repos into the parent
directory — offline bootstrap / recovery only; normally you clone individually.

## Infra & Kong

`make infra-up` starts (Docker Compose, project `mis-dev`):

| Component | Port(s) | Notes |
|-----------|---------|-------|
| Postgres 16 | 5432 | `mis` / `mis` / db `mis_dev` |
| Mongo 7 (single-node RS) | 27017 | `rs0` via `mongo-init` |
| Redis 7 | 6379 | |
| Zookeeper + Kafka | 29092 (host) | `kafka:9092` in-network; first `infra-up` waits ≤90s for the broker before creating topics |
| Kong 3.5 (DB-less) | 8000 proxy, 8001 admin, 8100 status | routes `/api/<domain>` → host services |

Kong reaches host services via `host.docker.internal` (Linux: mapped through
`extra_hosts: host-gateway`). Targets: `infra-up/down/ps/logs`, `reset`
(down -v + up), `kafka-init`, `kong-reload` (apply `docker/kong/kong.yml`
edits, no restart), `kong-token`, `kong-metrics`, `urls`.

## Gateway (Kong) — auth, rate limiting, metrics, correlation id

Cross-cutting concerns live at the gateway (`docker/kong/kong.yml`), not in
each service:

| Plugin | Scope | Effect |
|--------|-------|--------|
| `jwt` | every `<svc>` route (not `<svc>-public`) | HS256 + `exp` required; 401 at the edge |
| `rate-limiting` | global | 120 req/min per client IP |
| `prometheus` | global | metrics at `http://localhost:8100/metrics` |
| `correlation-id` | global | injects/propagates `X-Correlation-ID` (client value passes through) |

**Whitelisting:** `strip_path` is off — each service owns its real
`/api/<domain>` path (`app.setGlobalPrefix`). Every service has a `<svc>`
route (jwt) and a `<svc>-public` route (no jwt). Kong matches the longest
path first, so public paths win. To whitelist an endpoint, add its full path
to that service's `<svc>-public` route and `make kong-reload`. Currently
public: every `…/health` & `…/ready`, plus `/api/auth/login`.

**Auth/authz split:** Kong proves *who* (authN); services decide *what*
(authZ) using `@mis/auth-middleware` (`gatewayIdentity()` → `req.user` /
`req.correlationId`) and `@mis/access-control` (`accessGuard()`, `can()`,
`permissionsForRoles()` — 5 permissions, 2 roles).

| Role | Permissions |
|------|-------------|
| `case-officer` | `case:read` `case:write` `profile:read` |
| `reporting-analyst` | `reporting:read` `reporting:export` `profile:read` |

Test users in `mis-auth-svc` (`src/users.ts`): `caseofficer` / `case123`,
`reportanalyst` / `report123` (login by username or email).

```bash
G=localhost:8000
TOKEN=$(curl -s -X POST $G/api/auth/login -H 'content-type: application/json' \
  -d '{"usernameOrEmail":"caseofficer","password":"case123"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

RTOK=$(curl -s -X POST $G/api/auth/login -H 'content-type: application/json' \
  -d '{"usernameOrEmail":"reportanalyst","password":"report123"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

curl $G/api/cases/health                                 # 200 — whitelisted
curl $G/api/cases/                                       # 401 — no token
curl -H "Authorization: Bearer $TOKEN"  $G/api/cases/    # 200 — case-officer ok
curl -H "Authorization: Bearer $RTOK"   $G/api/cases/    # 403 — lacks case:read
make kong-metrics                                        # Kong counters
```

`make kong-token` mints a generic admin token for quick checks.
`requirements.http` (REST Client) exercises the whole matrix.

The signing secret is a throwaway dev value duplicated in `kong.yml` and
`scripts/mint-token.sh` (`JWT_SECRET`, default `mis-poc-dev-secret-change-me`)
— Kong's `jwt_secrets.secret` isn't vault-referenceable; wire a real secret
store before anything non-local.

## Shared `@mis/*` packages

Two ways a service resolves the 8 `@mis/*` packages (no monorepo workspaces
anymore — each repo is standalone):

| Mode | When | Command |
|------|------|---------|
| Git URLs | no feed yet | `make install-standalone` (pulls `git+ssh://…/mis-pkg-*.git`, no `package.json` edit) |
| **Azure feed** | production / CI | `make install-azure` |

**Azure Artifacts feed:**

1. Create the feed once: Azure DevOps → project → **Artifacts → Create Feed**
   (e.g. `mis-npm`); copy the npm registry URL.
2. Per repo: `cp .npmrc.example .npmrc` and set `<org>/<project>/<feed>`
   (real `.npmrc` is git-ignored).
3. Authenticate with `make auth` (cross-platform):
   - Linux/macOS/CI: `export AZURE_NPM_TOKEN="$(printf %s '<PAT>' | base64 | tr -d '\n')"` — npm expands `${AZURE_NPM_TOKEN}` from `.npmrc`.
   - Windows: falls back to `vsts-npm-auth`.
4. Consume: `make install-azure` (service). Publish: `npm version patch` then
   `make publish` (package; uses `npm publish --no-workspaces`).

This is the production layout in `architecture/04-shared-packages.md`. Once
published, switch a service's `@mis/*` specifiers to real ranges (`^0.1.0`)
so a plain `npm install` resolves from the feed via the scoped `.npmrc`.

## Architecture docs

`architecture/` (chapters `01`–`11` + `schema.dbml`) is the design source of
truth — service catalogue, comms rules, DB model, security, CI/CD,
integrations. Start at `architecture/README.md`.

## Persistence (later)

Each service Makefile already exposes `prisma-generate`, `prisma-migrate`,
`prisma-deploy`, `seed` (stubs). When a service gains a
`prisma/schema.prisma`, replace its stub targets with real `npx prisma …`
calls — run them from that service's own repo against the shared Postgres
(`localhost:5432`, db `mis_<domain>`).
