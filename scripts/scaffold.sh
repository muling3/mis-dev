#!/usr/bin/env bash
# One-shot generator for the remaining @mis/* packages and the 8 NestJS
# services. Idempotent: overwrites generated files, safe to re-run.
set -euo pipefail

ROOT="$(realpath "$(dirname "$0")/../..")"
cd "$ROOT"

# ─────────────────────────────────────────────────────────────
# Shared packages: name|description|extra-named-exports
# ─────────────────────────────────────────────────────────────
gen_pkg() {
  local repo="$1" pkg="$2" body="$3"
  mkdir -p "$repo/src"

  cat > "$repo/package.json" <<JSON
{
  "name": "$pkg",
  "version": "0.1.0",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "files": ["dist"],
  "publishConfig": { "access": "restricted" },
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "prepare": "npm run build",
    "clean": "rm -rf dist node_modules"
  },
  "devDependencies": {
    "@types/node": "^22.10.0",
    "typescript": "^5.4.5"
  }
}
JSON

  # Self-contained (no shared base): each repo is independent so teams can
  # pull a single folder and build it without the monorepo root.
  cat > "$repo/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "target": "ES2023",
    "module": "nodenext",
    "moduleResolution": "nodenext",
    "lib": ["ES2023"],
    "types": ["node"],
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "strict": false,
    "noImplicitAny": false,
    "declaration": true,
    "sourceMap": true,
    "experimentalDecorators": true,
    "emitDecoratorMetadata": true,
    "resolveJsonModule": true,
    "outDir": "dist",
    "rootDir": "./src"
  },
  "include": ["src/**/*"]
}
JSON

  cat > "$repo/Makefile" <<MK
PACKAGE := $pkg

.PHONY: help install auth build test lint pack publish clean

help:                  ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-16s %s\n", \$\$1, \$\$2}' \$(MAKEFILE_LIST)

install:               ## Install deps for this package (standalone)
	npm install

auth:                  ## Authenticate npm to the @mis Azure feed (cross-platform)
	@test -f .npmrc || { echo "no .npmrc — cp .npmrc.example .npmrc and set <org>/<project>/<feed>"; exit 1; }
	@if [ -n "\$\${AZURE_NPM_TOKEN:-}" ]; then \\
	  echo "auth: AZURE_NPM_TOKEN set — npm reads it from .npmrc (no action needed)"; \\
	elif uname -s 2>/dev/null | grep -qiE 'mingw|msys|cygwin|windows'; then \\
	  vsts-npm-auth -config .npmrc; \\
	else \\
	  echo "auth: no credentials. Linux/macOS/CI:  export AZURE_NPM_TOKEN=<base64 Azure PAT>"; \\
	  echo "      Windows: install vsts-npm-auth, then re-run 'make auth'"; \\
	  exit 1; \\
	fi

build:                 ## Compile TS to dist/
	rm -rf dist && npx tsc -p tsconfig.json

test:                  ## Run tests (stub)
	@echo "test: no tests yet for \$(PACKAGE)"

lint:                  ## Lint (stub)
	@echo "lint: not configured yet for \$(PACKAGE)"

pack:                  ## Build then npm pack
	\$(MAKE) build && npm pack

publish: auth build    ## Publish this package to the @mis Azure Artifacts feed
	npm publish --no-workspaces

clean:                 ## Remove artefacts
	rm -rf dist node_modules *.tgz
MK

  cat > "$repo/.npmrc.example" <<'NPMRC'
; Azure Artifacts npm registry for @mis/* packages. Cross-platform setup:
;   1) cp .npmrc.example .npmrc   and replace <org>/<project>/<feed> below
;   2) Linux/macOS/CI: export AZURE_NPM_TOKEN=<base64-encoded Azure PAT>
;      Windows:        run `make auth` (uses vsts-npm-auth)
;   3) services: make install-azure   |   packages: make publish
; npm expands ${AZURE_NPM_TOKEN} from the environment at run time; the real
; .npmrc is gitignored so no secret is ever committed.

@mis:registry=https://pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/npm/registry/
always-auth=true

//pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/npm/registry/:username=mis
//pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/npm/registry/:_password=${AZURE_NPM_TOKEN}
//pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/npm/registry/:email=npm@mis.local
//pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/npm/:username=mis
//pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/npm/:_password=${AZURE_NPM_TOKEN}
//pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/npm/:email=npm@mis.local
NPMRC

  # Each folder is its own git repo (teams pull a single repo), so it needs
  # its own .gitignore. Never track build output / incremental caches.
  cat > "$repo/.gitignore" <<'IGN'
node_modules/
dist/
*.tsbuildinfo
.env
.env.local
.npmrc
*.log
IGN

  printf '%s\n' "$body" > "$repo/src/index.ts"
  echo "  pkg  $pkg"
}

gen_pkg mis-pkg-audit-logger "@mis/audit-logger" '// @mis/audit-logger — STUB.
// Production: async hash-chained audit events to Kafka topic mis.audit.
// PoC: logs to stdout.
export const PACKAGE = "@mis/audit-logger";

export interface AuditEvent {
  action: string;
  actor: string;
  resource: { type: string; id: string };
  metadata?: Record<string, unknown>;
}

export class AuditLoggerService {
  async log(event: AuditEvent): Promise<void> {
    console.log(`[audit] ${event.action} by ${event.actor}`, event.resource);
  }
}

export function banner(): string {
  return `[${PACKAGE}] stub loaded`;
}'

gen_pkg mis-pkg-error-formatter "@mis/error-formatter" '// @mis/error-formatter — STUB.
// Production: RFC 7807 problem-details exception filter with correlation_id.
// PoC: plain shaping helper.
export const PACKAGE = "@mis/error-formatter";

export interface ProblemDetails {
  type: string;
  title: string;
  status: number;
  detail?: string;
  correlation_id?: string;
}

export function toProblemDetails(
  status: number,
  title: string,
  detail?: string,
): ProblemDetails {
  return { type: "about:blank", title, status, detail };
}

export function banner(): string {
  return `[${PACKAGE}] stub loaded`;
}'

gen_pkg mis-pkg-metrics "@mis/metrics" '// @mis/metrics — STUB.
// Production: prom-client wrapper exposing /metrics on internal port 9090.
// PoC: in-memory counter map.
export const PACKAGE = "@mis/metrics";

export interface MetricsOptions {
  serviceName: string;
}

const counters = new Map<string, number>();

export function inc(name: string, by = 1): void {
  counters.set(name, (counters.get(name) ?? 0) + by);
}

export function snapshot(): Record<string, number> {
  return Object.fromEntries(counters);
}

export function banner(): string {
  return `[${PACKAGE}] stub loaded`;
}'

gen_pkg mis-pkg-access-control "@mis/access-control" '// @mis/access-control — authZ model + guard (PoC).
// Kong (jwt plugin) handles authN; this decides what the authenticated user
// — read off the request by @mis/auth-middleware — may do INSIDE a service.
export const PACKAGE = "@mis/access-control";

// ── 5 permissions ─────────────────────────────────────────────
export const PERMISSIONS = [
  "case:read",
  "case:write",
  "reporting:read",
  "reporting:export",
  "profile:read",
] as const;
export type Permission = (typeof PERMISSIONS)[number];

// ── 2 roles → permissions ─────────────────────────────────────
export const ROLES: Record<string, Permission[]> = {
  "case-officer": ["case:read", "case:write", "profile:read"],
  "reporting-analyst": ["reporting:read", "reporting:export", "profile:read"],
};

export interface Principal {
  id: string;
  roles: string[];
}

/** Flatten a set of role names to the permissions they grant. */
export function permissionsForRoles(roles: string[] = []): Permission[] {
  const out = new Set<Permission>();
  for (const r of roles) for (const p of ROLES[r] ?? []) out.add(p);
  return [...out];
}

export function hasRole(user: Principal | undefined, role: string): boolean {
  return !!user && user.roles.includes(role);
}

/** `admin` may do anything; otherwise the permission must be role-granted. */
export function can(
  user: Principal | undefined,
  permission: string,
): boolean {
  if (!user) return false;
  if (user.roles.includes("admin")) return true;
  return permissionsForRoles(user.roles).includes(permission as Permission);
}

export interface AccessGuardOptions {
  /** Permission required for every route except `allow`. */
  permission: Permission;
  /** Exact request paths that skip the permission check (still need a token). */
  allow?: string[];
}

/**
 * Express/NestJS-style guard. Mount AFTER gatewayIdentity() so `req.user`
 * is populated. Whitelisted paths (`allow`) skip the check; everything else
 * needs `permission`. 403 with a helpful body otherwise.
 */
export function accessGuard(opts: AccessGuardOptions) {
  const allow = new Set(opts.allow ?? []);
  return (req: any, res: any, next: () => void) => {
    if (req.method === "OPTIONS" || allow.has(req.path)) return next();
    if (can(req.user, opts.permission)) return next();
    res.statusCode = 403;
    res.setHeader("content-type", "application/json");
    res.end(
      JSON.stringify({
        error: "forbidden",
        requiredPermission: opts.permission,
        yourRoles: req.user?.roles ?? [],
        yourPermissions: permissionsForRoles(req.user?.roles ?? []),
      }),
    );
  };
}

export function RequirePermission(permission: string): MethodDecorator {
  return (_t, _k, descriptor) => {
    (descriptor.value as any).__permission = permission;
    return descriptor;
  };
}

export function ResourceOwner(_opts: { entity: string; userField: string }): MethodDecorator {
  return (_t, _k, descriptor) => descriptor;
}

export function banner(): string {
  return `[${PACKAGE}] authz model loaded (${PERMISSIONS.length} perms, ${Object.keys(ROLES).length} roles)`;
}'

gen_pkg mis-pkg-validation-schemas "@mis/validation-schemas" '// @mis/validation-schemas — STUB.
// Production: shared Zod schemas reused by controllers + Kafka envelopes.
// PoC: trivial validators with no external deps.
export const PACKAGE = "@mis/validation-schemas";

export interface ApplicationSubmit {
  applicantName: string;
  type: string;
}

export function isApplicationSubmit(v: unknown): v is ApplicationSubmit {
  return (
    typeof v === "object" && v !== null &&
    typeof (v as any).applicantName === "string" &&
    typeof (v as any).type === "string"
  );
}

export function banner(): string {
  return `[${PACKAGE}] stub loaded`;
}'

gen_pkg mis-pkg-circuit-breaker "@mis/circuit-breaker" '// @mis/circuit-breaker — STUB.
// Production: opossum-wrapped HTTP client (timeout/threshold/reset).
// PoC: pass-through fetch wrapper, no breaker logic yet.
export const PACKAGE = "@mis/circuit-breaker";

export interface CircuitBreakerOptions {
  service: string;
  baseUrl: string;
}

export class CircuitBreakerClient {
  constructor(private readonly opts: CircuitBreakerOptions) {}

  async get(path: string): Promise<unknown> {
    const res = await fetch(`${this.opts.baseUrl}${path}`);
    return res.json();
  }
}

export function banner(): string {
  return `[${PACKAGE}] stub loaded`;
}'

gen_pkg mis-proto "@mis/proto" '// @mis/proto — STUB.
// Production: generated gRPC clients/types from mis-proto/proto/*.proto.
// PoC: typed placeholders so callers compile.
export const PACKAGE = "@mis/proto";

export interface ValidateTokenRequest { token: string; }
export interface ValidateTokenResponse { valid: boolean; userId?: string; }

export class AuthServiceClient {
  async validateToken(req: ValidateTokenRequest): Promise<ValidateTokenResponse> {
    return { valid: Boolean(req.token), userId: "dev-user" };
  }
}

export function banner(): string {
  return `[${PACKAGE}] stub loaded`;
}'

# ─────────────────────────────────────────────────────────────
# NestJS services: domain|port
# ─────────────────────────────────────────────────────────────
gen_service() {
  local domain="$1" port="$2" route="$3" perm="${4:-profile:read}"
  local repo="mis-${domain}-service"
  local prefix="${route#/}"
  # Whitelisted in-service paths (skip the authz check; still token-gated
  # by Kong except health/ready which are also public in kong.yml).
  local allow="'/$prefix/health', '/$prefix/ready', '/$prefix/me'"
  [ "$domain" = "auth" ] && allow="$allow, '/api/auth/login'"
  mkdir -p "$repo/src"

  cat > "$repo/package.json" <<JSON
{
  "name": "$repo",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "build": "nest build",
    "start": "node dist/main.js",
    "start:dev": "nest start --watch",
    "lint": "echo \"lint: not configured yet\"",
    "test": "echo \"test: no tests yet\"",
    "typecheck": "tsc -p tsconfig.json --noEmit",
    "seed": "echo \"seed: no Prisma schema yet\""
  },
  "dependencies": {
    "@nestjs/common": "^10.4.4",
    "@nestjs/core": "^10.4.4",
    "@nestjs/platform-express": "^10.4.4",
    "reflect-metadata": "^0.2.2",
    "rxjs": "^7.8.1",
    "@mis/auth-middleware": "*",
    "@mis/audit-logger": "*",
    "@mis/error-formatter": "*",
    "@mis/metrics": "*",
    "@mis/access-control": "*",
    "@mis/validation-schemas": "*",
    "@mis/circuit-breaker": "*",
    "@mis/proto": "*"
  },
  "devDependencies": {
    "@nestjs/cli": "^10.4.5",
    "@nestjs/schematics": "^10.1.4",
    "@types/node": "^22.10.0",
    "typescript": "^5.4.5",
    "ts-node": "^10.9.2",
    "ts-loader": "^9.5.1"
  }
}
JSON

  cat > "$repo/nest-cli.json" <<'JSON'
{
  "$schema": "https://json.schemastore.org/nest-cli",
  "collection": "@nestjs/schematics",
  "sourceRoot": "src",
  "compilerOptions": { "deleteOutDir": true }
}
JSON

  # Self-contained (no shared base): each service repo is independent.
  cat > "$repo/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "target": "ES2023",
    "module": "nodenext",
    "moduleResolution": "nodenext",
    "lib": ["ES2023"],
    "types": ["node"],
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "strict": false,
    "noImplicitAny": false,
    "declaration": true,
    "sourceMap": true,
    "experimentalDecorators": true,
    "emitDecoratorMetadata": true,
    "resolveJsonModule": true,
    "outDir": "./dist",
    "rootDir": "./src",
    "incremental": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist"]
}
JSON

  cat > "$repo/tsconfig.build.json" <<'JSON'
{
  "extends": "./tsconfig.json",
  "exclude": ["node_modules", "dist", "test", "**/*spec.ts"]
}
JSON

  cat > "$repo/.env.example" <<ENV
NODE_ENV=development
PORT=$port

# Wire these as features land (see architecture/06, 03, 08):
DATABASE_URL=postgresql://mis:mis@localhost:5432/mis_${domain}?schema=public
REDIS_URL=redis://localhost:6379
KAFKA_BROKERS=localhost:29092
AUTH_JWKS_URI=http://localhost:3001/.well-known/jwks.json
LOG_LEVEL=debug
ENV

  cat > "$repo/.dockerignore" <<'IGN'
.git
node_modules
dist
.env
*.log
IGN

  # Each service is its own git repo — needs its own .gitignore. Build
  # output and *.tsbuildinfo (incremental cache) must never be tracked.
  cat > "$repo/.gitignore" <<'IGN'
node_modules/
dist/
*.tsbuildinfo
.env
.env.local
.npmrc
*.log
IGN

  cat > "$repo/.npmrc.example" <<'NPMRC'
; Azure Artifacts npm registry for @mis/* packages. Cross-platform setup:
;   1) cp .npmrc.example .npmrc   and replace <org>/<project>/<feed> below
;   2) Linux/macOS/CI: export AZURE_NPM_TOKEN=<base64-encoded Azure PAT>
;      Windows:        run `make auth` (uses vsts-npm-auth)
;   3) services: make install-azure   |   packages: make publish
; npm expands ${AZURE_NPM_TOKEN} from the environment at run time; the real
; .npmrc is gitignored so no secret is ever committed.

@mis:registry=https://pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/npm/registry/
always-auth=true

//pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/npm/registry/:username=mis
//pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/npm/registry/:_password=${AZURE_NPM_TOKEN}
//pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/npm/registry/:email=npm@mis.local
//pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/npm/:username=mis
//pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/npm/:_password=${AZURE_NPM_TOKEN}
//pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/npm/:email=npm@mis.local
NPMRC

  cat > "$repo/src/main.ts" <<TS
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';
import { banner as authBanner, gatewayIdentity } from '@mis/auth-middleware';
import { banner as acBanner, accessGuard } from '@mis/access-control';

const PREFIX = '$prefix';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);

  // Kong already authenticated the caller (jwt plugin). These read the
  // forwarded identity and enforce per-service authorization.
  app.use(gatewayIdentity());
  app.use(
    accessGuard({
      permission: '$perm',
      allow: [$allow],
    }),
  );

  app.setGlobalPrefix(PREFIX);
  const port = Number(process.env.PORT) || $port;
  await app.listen(port);
  console.log(authBanner());
  console.log(acBanner());
  console.log(\`$repo listening on http://localhost:\${port}/\${PREFIX}\`);
}
bootstrap();
TS

  # NOTE: mis-auth-service additionally registers AuthController (POST /login,
  # added outside this generator). Re-running scaffold resets this to generic;
  # restore the auth login wiring afterwards if you regenerate it.
  cat > "$repo/src/app.module.ts" <<'TS'
import { Module } from '@nestjs/common';
import { AppController } from './app.controller';

@Module({
  controllers: [AppController],
})
export class AppModule {}
TS

  cat > "$repo/src/app.controller.ts" <<TS
import { Controller, Get, Req } from '@nestjs/common';
import { permissionsForRoles } from '@mis/access-control';

const SERVICE = '$repo';

@Controller()
export class AppController {
  // Functional route — requires the '$perm' permission (accessGuard).
  @Get()
  index() {
    return { service: SERVICE, message: 'hello from $domain', route: '/$prefix' };
  }

  // Whoami — any authenticated user may introspect their own identity,
  // roles and resolved permissions on any service.
  @Get('me')
  me(@Req() req: any) {
    return {
      service: SERVICE,
      user: req.user ?? null,
      correlationId: req.correlationId ?? null,
      roles: req.user?.roles ?? [],
      permissions: permissionsForRoles(req.user?.roles ?? []),
    };
  }

  @Get('health')
  health() {
    return { status: 'ok', service: SERVICE };
  }

  @Get('ready')
  ready() {
    return { status: 'ready', service: SERVICE };
  }
}
TS

  cat > "$repo/Makefile" <<MK
SERVICE := ${domain}-service
IMAGE   := mis/\$(SERVICE)
TAG     ?= dev

.PHONY: help install install-standalone install-azure auth dev build start test lint typecheck \\
        prisma-generate prisma-migrate prisma-deploy seed \\
        docker-build clean

help:                  ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-18s %s\n", \$\$1, \$\$2}' \$(MAKEFILE_LIST)

install:               ## Install deps for this service (standalone)
	npm install

install-standalone:    ## Install deps + @mis/* from GitHub (no package.json edit)
	npm install --no-save \\
	  git+ssh://git@github.com/muling3/mis-pkg-auth-middleware.git \\
	  git+ssh://git@github.com/muling3/mis-pkg-audit-logger.git \\
	  git+ssh://git@github.com/muling3/mis-pkg-error-formatter.git \\
	  git+ssh://git@github.com/muling3/mis-pkg-metrics.git \\
	  git+ssh://git@github.com/muling3/mis-pkg-access-control.git \\
	  git+ssh://git@github.com/muling3/mis-pkg-validation-schemas.git \\
	  git+ssh://git@github.com/muling3/mis-pkg-circuit-breaker.git \\
	  git+ssh://git@github.com/muling3/mis-proto.git

auth:                  ## Authenticate npm to the @mis Azure feed (cross-platform)
	@test -f .npmrc || { echo "no .npmrc — cp .npmrc.example .npmrc and set <org>/<project>/<feed>"; exit 1; }
	@if [ -n "\$\${AZURE_NPM_TOKEN:-}" ]; then \\
	  echo "auth: AZURE_NPM_TOKEN set — npm reads it from .npmrc (no action needed)"; \\
	elif uname -s 2>/dev/null | grep -qiE 'mingw|msys|cygwin|windows'; then \\
	  vsts-npm-auth -config .npmrc; \\
	else \\
	  echo "auth: no credentials. Linux/macOS/CI:  export AZURE_NPM_TOKEN=<base64 Azure PAT>"; \\
	  echo "      Windows: install vsts-npm-auth, then re-run 'make auth'"; \\
	  exit 1; \\
	fi

install-azure: auth    ## Install @mis/* from the Azure Artifacts feed (.npmrc)
	npm install

dev:                   ## Run in watch mode
	npm run start:dev

build:                 ## nest build
	npm run build

start:                 ## Run compiled build
	npm start

test:                  ## Unit tests (stub)
	npm test

lint:                  ## Lint (stub)
	npm run lint

typecheck:             ## tsc --noEmit
	npm run typecheck

prisma-generate:       ## STUB — no Prisma schema yet
	@echo "prisma-generate: TODO for \$(SERVICE)"

prisma-migrate:        ## STUB
	@echo "prisma-migrate: TODO for \$(SERVICE)"

prisma-deploy:         ## STUB
	@echo "prisma-deploy: TODO for \$(SERVICE)"

seed:                  ## STUB
	@echo "seed: TODO for \$(SERVICE)"

docker-build:          ## Build Docker image (needs configured .npmrc + AZURE_NPM_TOKEN)
	@test -f .npmrc || { echo "cp .npmrc.example .npmrc and set <org>/<project>/<feed>"; exit 1; }
	@test -n "\$\${AZURE_NPM_TOKEN:-}" || { echo "export AZURE_NPM_TOKEN=<base64 Azure PAT> first"; exit 1; }
	DOCKER_BUILDKIT=1 docker build --secret id=azure_npm_token,env=AZURE_NPM_TOKEN -t \$(IMAGE):\$(TAG) .

clean:                 ## Remove build artefacts
	rm -rf dist node_modules
MK

  # Dockerfile builds from the monorepo root so workspace deps resolve.
  cat > "$repo/Dockerfile" <<DOCKER
# syntax=docker/dockerfile:1
# Standalone build — context is THIS service repo only (no monorepo).
# @mis/* are pulled from the Azure Artifacts feed; the token is passed as a
# BuildKit secret so it never lands in an image layer. Requires a configured
# .npmrc (cp .npmrc.example .npmrc; set <org>/<project>/<feed>) and:
#   export AZURE_NPM_TOKEN=<base64 Azure PAT>
#   make docker-build
# (equiv: DOCKER_BUILDKIT=1 docker build \\
#   --secret id=azure_npm_token,env=AZURE_NPM_TOKEN -t mis/${domain}-service:dev .)
FROM node:22-alpine AS builder
WORKDIR /app
COPY package.json package-lock.json* .npmrc ./
RUN --mount=type=secret,id=azure_npm_token \\
    AZURE_NPM_TOKEN="\$(cat /run/secrets/azure_npm_token 2>/dev/null)" \\
    npm install --no-audit --no-fund
COPY tsconfig.json nest-cli.json ./
COPY src ./src
RUN npm run build

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json* .npmrc ./
RUN --mount=type=secret,id=azure_npm_token \\
    AZURE_NPM_TOKEN="\$(cat /run/secrets/azure_npm_token 2>/dev/null)" \\
    npm install --omit=dev --no-audit --no-fund
COPY --from=builder /app/dist ./dist
EXPOSE $port
CMD ["node", "dist/main.js"]
DOCKER

  echo "  svc  $repo (:$port)"
}

# gen_service <domain> <port> <route> [required-permission]
gen_service auth         3001 /api/auth          profile:read
gen_service registration 3002 /api/registration  profile:read
gen_service case         3003 /api/cases         case:read
gen_service sandbox      3004 /api/sandbox       profile:read
gen_service notification 3005 /api/notifications profile:read
gen_service reporting    3006 /api/reporting     reporting:read
gen_service document     3007 /api/documents     profile:read
gen_service admin        3008 /api/admin         profile:read

chmod +x "$ROOT/mis-dev/scripts/"*.sh
echo "Scaffold complete."
