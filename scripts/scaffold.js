#!/usr/bin/env node
// One-shot generator for the @mis/* packages and the 8 NestJS service repos.
// Idempotent — overwrites generated files, safe to re-run.
//
// Cross-platform: pure Node (fs/path). No bash, no heredocs, no coreutils.
// JS template literals always emit LF, so generated files are line-ending
// clean on Linux, macOS, and Windows alike.

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
process.chdir(ROOT);

console.log(`This regenerates the full set of repos in ${ROOT} — for`);
console.log('offline bootstrap/recovery only. Normally you clone repos individually.');

const write = (rel, content) => {
  const abs = path.join(ROOT, rel);
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  fs.writeFileSync(abs, content);
};

// ── Shared boilerplate (identical across every package and service repo) ──

const PKG_TSCONFIG = `{
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
`;

const SVC_TSCONFIG = `{
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
    "rootDir": "./src"
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist"]
}
`;

const SVC_TSCONFIG_BUILD = `{
  "extends": "./tsconfig.json",
  "exclude": ["node_modules", "dist", "test", "**/*spec.ts"]
}
`;

const NEST_CLI_JSON = `{
  "$schema": "https://json.schemastore.org/nest-cli",
  "collection": "@nestjs/schematics",
  "sourceRoot": "src",
  "compilerOptions": { "deleteOutDir": true }
}
`;

const NPMRC_EXAMPLE = `; Azure Artifacts npm registry for @mis/* packages. Cross-platform setup:
;   1) cp .npmrc.example .npmrc   and replace <org>/<project>/<feed> below
;   2) Linux/macOS/CI: export AZURE_NPM_TOKEN=<base64-encoded Azure PAT>
;      Windows:        run \`make auth\` (uses vsts-npm-auth)
;   3) services: make install-azure   |   packages: make publish
; npm expands \${AZURE_NPM_TOKEN} from the environment at run time; the real
; .npmrc is gitignored so no secret is ever committed.

@mis:registry=https://pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/npm/registry/
always-auth=true

//pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/npm/registry/:username=mis
//pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/npm/registry/:_password=\${AZURE_NPM_TOKEN}
//pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/npm/registry/:email=npm@mis.local
//pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/npm/:username=mis
//pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/npm/:_password=\${AZURE_NPM_TOKEN}
//pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/npm/:email=npm@mis.local
`;

const GITIGNORE = `node_modules/
dist/
*.tsbuildinfo
.env
.env.local
.npmrc
*.log
`;

const DOCKERIGNORE = `.git
node_modules
dist
.env
*.log
`;

const APP_MODULE_TS = `import { Module } from '@nestjs/common';
import { AppController } from './app.controller';

@Module({
  controllers: [AppController],
})
export class AppModule {}
`;

// ── Cross-platform helper scripts written into every generated repo ───────
// Each generated Makefile recipe is a single \`node scripts/*.js\` call so
// recipes run unchanged under cmd.exe, PowerShell, sh, and bash. The scripts
// below replace the bash-only awk/test/uname/rm -rf/DOCKER_BUILDKIT= bits.

const SHELL_DETECT = `ifeq ($(OS),Windows_NT)
  SHELL := cmd.exe
  .SHELLFLAGS := /C
else
  SHELL := /bin/sh
endif

`;

const SCRIPT_HELP = `#!/usr/bin/env node
// Parse the local Makefile for '## ...' help comments and print them.

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const text = fs.readFileSync(path.join(__dirname, '..', 'Makefile'), 'utf8');
for (const line of text.split(/\\r?\\n/)) {
  const m = line.match(/^([a-zA-Z_-]+):.*?## (.*)$/);
  if (m) console.log(\`  \${m[1].padEnd(18)} \${m[2]}\`);
}
`;

const SCRIPT_AUTH = `#!/usr/bin/env node
// Cross-platform npm auth for the @mis Azure Artifacts feed.
//   Linux/macOS/CI: expect AZURE_NPM_TOKEN env var (base64 Azure PAT).
//   Windows:        fall back to vsts-npm-auth (must be installed).

'use strict';

const fs = require('node:fs');
const { spawnSync } = require('node:child_process');

if (!fs.existsSync('.npmrc')) {
  console.error('no .npmrc — cp .npmrc.example .npmrc and set <org>/<project>/<feed>');
  process.exit(1);
}

if (process.env.AZURE_NPM_TOKEN) {
  console.log('auth: AZURE_NPM_TOKEN set — npm reads it from .npmrc (no action needed)');
  process.exit(0);
}

if (process.platform === 'win32') {
  const r = spawnSync('vsts-npm-auth', ['-config', '.npmrc'], {
    stdio: 'inherit',
    shell: true,
  });
  process.exit(r.status ?? 1);
}

console.error('auth: no credentials. Linux/macOS/CI:  export AZURE_NPM_TOKEN=<base64 Azure PAT>');
console.error("      Windows: install vsts-npm-auth, then re-run 'make auth'");
process.exit(1);
`;

const SCRIPT_CLEAN = `#!/usr/bin/env node
// Remove build artefacts (dist/, node_modules/, *.tgz). Cross-platform
// replacement for \`rm -rf dist node_modules *.tgz\`.

'use strict';

const fs = require('node:fs');

for (const t of ['dist', 'node_modules']) {
  try { fs.rmSync(t, { recursive: true, force: true }); } catch {}
}
try {
  for (const f of fs.readdirSync('.')) {
    if (f.endsWith('.tgz')) fs.rmSync(f, { force: true });
  }
} catch {}
`;

const SCRIPT_INSTALL_STANDALONE = `#!/usr/bin/env node
// Install @mis/* packages directly from the public GitHub repos over HTTPS
// (no .npmrc, no Azure feed credentials). Cross-platform replacement for
// the multi-line bash \`npm install --no-save\` chain.

'use strict';

const { spawnSync } = require('node:child_process');

const URLS = [
  'git+https://github.com/muling3/mis-pkg-auth-middleware.git',
  'git+https://github.com/muling3/mis-pkg-audit-logger.git',
  'git+https://github.com/muling3/mis-pkg-error-formatter.git',
  'git+https://github.com/muling3/mis-pkg-metrics.git',
  'git+https://github.com/muling3/mis-pkg-access-control.git',
  'git+https://github.com/muling3/mis-pkg-validation-schemas.git',
  'git+https://github.com/muling3/mis-pkg-circuit-breaker.git',
  'git+https://github.com/muling3/mis-proto.git',
];

const r = spawnSync('npm', ['install', '--no-save', ...URLS], {
  stdio: 'inherit',
  shell: true,
});
process.exit(r.status ?? 1);
`;

const SCRIPT_DOCKER_BUILD = `#!/usr/bin/env node
// Build the service's Docker image with BuildKit + the Azure feed token
// injected as a secret. Cross-platform replacement for the bash:
//   DOCKER_BUILDKIT=1 docker build --secret id=azure_npm_token,env=... -t IMAGE:TAG .

'use strict';

const fs = require('node:fs');
const { spawnSync } = require('node:child_process');

const [, , image, tag = 'dev'] = process.argv;
if (!image) {
  console.error('usage: node scripts/docker-build.js <image> [tag]');
  process.exit(1);
}
if (!fs.existsSync('.npmrc')) {
  console.error('cp .npmrc.example .npmrc and set <org>/<project>/<feed>');
  process.exit(1);
}
if (!process.env.AZURE_NPM_TOKEN) {
  console.error('export AZURE_NPM_TOKEN=<base64 Azure PAT> first');
  process.exit(1);
}

const r = spawnSync(
  'docker',
  [
    'build',
    '--secret', 'id=azure_npm_token,env=AZURE_NPM_TOKEN',
    '-t', \`\${image}:\${tag}\`,
    '.',
  ],
  { stdio: 'inherit', env: { ...process.env, DOCKER_BUILDKIT: '1' } },
);
process.exit(r.status ?? 1);
`;

// ── Per-package files ────────────────────────────────────────────────────

const pkgPackageJson = (pkg) => `{
  "name": "${pkg}",
  "version": "0.1.0",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "files": ["dist"],
  "publishConfig": { "access": "restricted" },
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "prepare": "npm run build",
    "clean": "node scripts/clean.js"
  },
  "devDependencies": {
    "@types/node": "^22.10.0",
    "typescript": "^5.4.5"
  }
}
`;

const pkgMakefile = (pkg) => `PACKAGE := ${pkg}

${SHELL_DETECT}.PHONY: help install auth build test lint pack publish clean

help:                  ## Show this help
\t@node scripts/help.js

install:               ## Install deps for this package (standalone)
\tnpm install

auth:                  ## Authenticate npm to the @mis Azure feed (cross-platform)
\t@node scripts/auth.js

build:                 ## Compile TS to dist/
\t@node -e "require('fs').rmSync('dist',{recursive:true,force:true})"
\tnpx tsc -p tsconfig.json

test:                  ## Run tests (stub)
\t@node -e "console.log('test: no tests yet for $(PACKAGE)')"

lint:                  ## Lint (stub)
\t@node -e "console.log('lint: not configured yet for $(PACKAGE)')"

pack:                  ## Build then npm pack
\t$(MAKE) build
\tnpm pack

publish: auth build    ## Publish this package to the @mis Azure Artifacts feed
\tnpm publish --no-workspaces

clean:                 ## Remove artefacts
\t@node scripts/clean.js
`;

function genPkg(repo, pkg, body) {
  write(`${repo}/package.json`, pkgPackageJson(pkg));
  // Self-contained (no shared base): each repo is independent so teams can
  // pull a single folder and build it without the monorepo root.
  write(`${repo}/tsconfig.json`, PKG_TSCONFIG);
  write(`${repo}/Makefile`, pkgMakefile(pkg));
  write(`${repo}/.npmrc.example`, NPMRC_EXAMPLE);
  // Each folder is its own git repo; needs its own .gitignore. Never track
  // build output / incremental caches.
  write(`${repo}/.gitignore`, GITIGNORE);
  write(`${repo}/src/index.ts`, body + '\n');
  // Cross-platform helpers the Makefile recipes shell out to.
  write(`${repo}/scripts/help.js`, SCRIPT_HELP);
  write(`${repo}/scripts/auth.js`, SCRIPT_AUTH);
  write(`${repo}/scripts/clean.js`, SCRIPT_CLEAN);
  console.log(`  pkg  ${pkg}`);
}

// ── Package bodies (TS source for each @mis/* package) ───────────────────

const BODY_AUDIT_LOGGER = `// @mis/audit-logger — STUB.
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
    console.log(\`[audit] \${event.action} by \${event.actor}\`, event.resource);
  }
}

export function banner(): string {
  return \`[\${PACKAGE}] stub loaded\`;
}`;

const BODY_ERROR_FORMATTER = `// @mis/error-formatter — STUB.
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
  return \`[\${PACKAGE}] stub loaded\`;
}`;

const BODY_METRICS = `// @mis/metrics — STUB.
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
  return \`[\${PACKAGE}] stub loaded\`;
}`;

const BODY_ACCESS_CONTROL = `// @mis/access-control — authZ model + guard (PoC).
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

/** \`admin\` may do anything; otherwise the permission must be role-granted. */
export function can(
  user: Principal | undefined,
  permission: string,
): boolean {
  if (!user) return false;
  if (user.roles.includes("admin")) return true;
  return permissionsForRoles(user.roles).includes(permission as Permission);
}

export interface AccessGuardOptions {
  /** Permission required for every route except \`allow\`. */
  permission: Permission;
  /** Exact request paths that skip the permission check (still need a token). */
  allow?: string[];
}

/**
 * Express/NestJS-style guard. Mount AFTER gatewayIdentity() so \`req.user\`
 * is populated. Whitelisted paths (\`allow\`) skip the check; everything else
 * needs \`permission\`. 403 with a helpful body otherwise.
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
  return \`[\${PACKAGE}] authz model loaded (\${PERMISSIONS.length} perms, \${Object.keys(ROLES).length} roles)\`;
}`;

const BODY_VALIDATION_SCHEMAS = `// @mis/validation-schemas — STUB.
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
  return \`[\${PACKAGE}] stub loaded\`;
}`;

const BODY_CIRCUIT_BREAKER = `// @mis/circuit-breaker — STUB.
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
    const res = await fetch(\`\${this.opts.baseUrl}\${path}\`);
    return res.json();
  }
}

export function banner(): string {
  return \`[\${PACKAGE}] stub loaded\`;
}`;

const BODY_PROTO = `// @mis/proto — STUB.
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
  return \`[\${PACKAGE}] stub loaded\`;
}`;

// ── Per-service files ────────────────────────────────────────────────────

const svcPackageJson = (repo) => `{
  "name": "${repo}",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "build": "nest build",
    "start": "node dist/main.js",
    "start:dev": "nest start --watch",
    "lint": "echo \\"lint: not configured yet\\"",
    "test": "echo \\"test: no tests yet\\"",
    "typecheck": "tsc -p tsconfig.json --noEmit",
    "seed": "echo \\"seed: no Prisma schema yet\\""
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
`;

const svcEnvExample = (domain, port) => `NODE_ENV=development
PORT=${port}

# Wire these as features land (see architecture/06, 03, 08):
DATABASE_URL=postgresql://mis:mis@localhost:5432/mis_${domain}?schema=public
REDIS_URL=redis://localhost:6379
KAFKA_BROKERS=localhost:29092
AUTH_JWKS_URI=http://localhost:3001/.well-known/jwks.json
LOG_LEVEL=debug
`;

const svcMainTs = (repo, prefix, perm, port, allow) => `import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';
import { banner as authBanner, gatewayIdentity } from '@mis/auth-middleware';
import { banner as acBanner, accessGuard } from '@mis/access-control';

const PREFIX = '${prefix}';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);

  // Kong already authenticated the caller (jwt plugin). These read the
  // forwarded identity and enforce per-service authorization.
  app.use(gatewayIdentity());
  app.use(
    accessGuard({
      permission: '${perm}',
      allow: [${allow}],
    }),
  );

  app.setGlobalPrefix(PREFIX);
  const port = Number(process.env.PORT) || ${port};
  await app.listen(port);
  console.log(authBanner());
  console.log(acBanner());
  console.log(\`${repo} listening on http://localhost:\${port}/\${PREFIX}\`);
}
bootstrap();
`;

const svcAppControllerTs = (repo, domain, prefix, perm) => `import { Controller, Get, Req } from '@nestjs/common';
import { permissionsForRoles } from '@mis/access-control';

const SERVICE = '${repo}';

@Controller()
export class AppController {
  // Functional route — requires the '${perm}' permission (accessGuard).
  @Get()
  index() {
    return { service: SERVICE, message: 'hello from ${domain}', route: '/${prefix}' };
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
`;

const svcMakefile = (domain) => `SERVICE := ${domain}-service
IMAGE   := mis/$(SERVICE)
TAG     ?= dev

${SHELL_DETECT}.PHONY: help install install-standalone install-azure auth dev build start test lint typecheck \\
        prisma-generate prisma-migrate prisma-deploy seed \\
        docker-build clean

help:                  ## Show this help
\t@node scripts/help.js

install:               ## Install deps for this service (standalone)
\tnpm install

install-standalone:    ## Install deps + @mis/* from GitHub (no package.json edit)
\tnode scripts/install-standalone.js

auth:                  ## Authenticate npm to the @mis Azure feed (cross-platform)
\t@node scripts/auth.js

install-azure: auth    ## Install @mis/* from the Azure Artifacts feed (.npmrc)
\tnpm install

dev:                   ## Run in watch mode
\tnpm run start:dev

build:                 ## nest build
\tnpm run build

start:                 ## Run compiled build
\tnpm start

test:                  ## Unit tests (stub)
\tnpm test

lint:                  ## Lint (stub)
\tnpm run lint

typecheck:             ## tsc --noEmit
\tnpm run typecheck

prisma-generate:       ## STUB — no Prisma schema yet
\t@node -e "console.log('prisma-generate: TODO for $(SERVICE)')"

prisma-migrate:        ## STUB
\t@node -e "console.log('prisma-migrate: TODO for $(SERVICE)')"

prisma-deploy:         ## STUB
\t@node -e "console.log('prisma-deploy: TODO for $(SERVICE)')"

seed:                  ## STUB
\t@node -e "console.log('seed: TODO for $(SERVICE)')"

docker-build:          ## Build Docker image (needs configured .npmrc + AZURE_NPM_TOKEN)
\t@node scripts/docker-build.js $(IMAGE) $(TAG)

clean:                 ## Remove build artefacts
\t@node scripts/clean.js
`;

const svcDockerfile = (domain, port) => `# syntax=docker/dockerfile:1
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
    AZURE_NPM_TOKEN="$(cat /run/secrets/azure_npm_token 2>/dev/null)" \\
    npm install --no-audit --no-fund
COPY tsconfig.json nest-cli.json ./
COPY src ./src
RUN npm run build

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json* .npmrc ./
RUN --mount=type=secret,id=azure_npm_token \\
    AZURE_NPM_TOKEN="$(cat /run/secrets/azure_npm_token 2>/dev/null)" \\
    npm install --omit=dev --no-audit --no-fund
COPY --from=builder /app/dist ./dist
EXPOSE ${port}
CMD ["node", "dist/main.js"]
`;

function genService(domain, port, route, perm = 'profile:read') {
  const repo = `mis-${domain}-service`;
  const prefix = route.replace(/^\//, '');
  // Whitelisted in-service paths (skip the authz check; still token-gated
  // by Kong except health/ready which are also public in kong.yml).
  let allow = `'/${prefix}/health', '/${prefix}/ready', '/${prefix}/me'`;
  if (domain === 'auth') allow += `, '/api/auth/login'`;

  write(`${repo}/package.json`, svcPackageJson(repo));
  write(`${repo}/nest-cli.json`, NEST_CLI_JSON);
  // Self-contained (no shared base): each service repo is independent.
  write(`${repo}/tsconfig.json`, SVC_TSCONFIG);
  write(`${repo}/tsconfig.build.json`, SVC_TSCONFIG_BUILD);
  write(`${repo}/.env.example`, svcEnvExample(domain, port));
  write(`${repo}/.dockerignore`, DOCKERIGNORE);
  // Each service is its own git repo — needs its own .gitignore. Build
  // output and *.tsbuildinfo (incremental cache) must never be tracked.
  write(`${repo}/.gitignore`, GITIGNORE);
  write(`${repo}/.npmrc.example`, NPMRC_EXAMPLE);
  write(`${repo}/src/main.ts`, svcMainTs(repo, prefix, perm, port, allow));
  // NOTE: mis-auth-service additionally registers AuthController (POST /login,
  // added outside this generator). Re-running scaffold resets this to generic;
  // restore the auth login wiring afterwards if you regenerate it.
  write(`${repo}/src/app.module.ts`, APP_MODULE_TS);
  write(`${repo}/src/app.controller.ts`, svcAppControllerTs(repo, domain, prefix, perm));
  write(`${repo}/Makefile`, svcMakefile(domain));
  // Dockerfile builds from each service's own repo context.
  write(`${repo}/Dockerfile`, svcDockerfile(domain, port));
  // Cross-platform helpers the Makefile recipes shell out to.
  write(`${repo}/scripts/help.js`, SCRIPT_HELP);
  write(`${repo}/scripts/auth.js`, SCRIPT_AUTH);
  write(`${repo}/scripts/clean.js`, SCRIPT_CLEAN);
  write(`${repo}/scripts/install-standalone.js`, SCRIPT_INSTALL_STANDALONE);
  write(`${repo}/scripts/docker-build.js`, SCRIPT_DOCKER_BUILD);

  console.log(`  svc  ${repo} (:${port})`);
}

// ── Generation ──────────────────────────────────────────────────────────

genPkg('mis-pkg-audit-logger',       '@mis/audit-logger',       BODY_AUDIT_LOGGER);
genPkg('mis-pkg-error-formatter',    '@mis/error-formatter',    BODY_ERROR_FORMATTER);
genPkg('mis-pkg-metrics',            '@mis/metrics',            BODY_METRICS);
genPkg('mis-pkg-access-control',     '@mis/access-control',     BODY_ACCESS_CONTROL);
genPkg('mis-pkg-validation-schemas', '@mis/validation-schemas', BODY_VALIDATION_SCHEMAS);
genPkg('mis-pkg-circuit-breaker',    '@mis/circuit-breaker',    BODY_CIRCUIT_BREAKER);
genPkg('mis-proto',                  '@mis/proto',              BODY_PROTO);

genService('auth',         3001, '/api/auth',          'profile:read');
genService('registration', 3002, '/api/registration',  'profile:read');
genService('case',         3003, '/api/cases',         'case:read');
genService('sandbox',      3004, '/api/sandbox',       'profile:read');
genService('notification', 3005, '/api/notifications', 'profile:read');
genService('reporting',    3006, '/api/reporting',     'reporting:read');
genService('document',     3007, '/api/documents',     'profile:read');
genService('admin',        3008, '/api/admin',         'profile:read');

// Mirror the .sh's final step: keep the scripts directly executable on POSIX.
// chmod is a no-op on Windows filesystems, so this is safe to always run.
for (const f of ['kafka-init.js', 'mint-token.js', 'scaffold.js']) {
  try { fs.chmodSync(path.join(ROOT, 'mis-dev', 'scripts', f), 0o755); } catch {}
}

console.log('Scaffold complete.');
