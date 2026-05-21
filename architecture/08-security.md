# 08 — Security Architecture

## Table of Contents

1. [Security Posture](#1-security-posture)
2. [Threat Model Summary](#2-threat-model-summary)
3. [Zero-Trust Implementation (Six Mechanisms)](#3-zero-trust-implementation-six-mechanisms)
4. [Defence in Depth — Five Layers](#4-defence-in-depth--five-layers)
5. [Identity & Authentication](#5-identity--authentication)
6. [Authorization & RBAC Matrix](#6-authorization--rbac-matrix)
7. [Encryption Architecture](#7-encryption-architecture)
8. [Secrets Management — Vault](#8-secrets-management--vault)
9. [Network Security](#9-network-security)
10. [Egress Proxy (Squid)](#10-egress-proxy-squid)
11. [Pod & Workload Hardening](#11-pod--workload-hardening)
12. [Sandbox Isolation](#12-sandbox-isolation)
13. [Auditing & Tamper-Evidence](#13-auditing--tamper-evidence)
14. [Supply Chain Security](#14-supply-chain-security)
15. [OWASP Top 10 Control Mapping](#15-owasp-top-10-control-mapping)
16. [Compliance & Validation](#16-compliance--validation)
17. [Incident Response](#17-incident-response)

---

## 1. Security Posture

MIS implements **zero trust** — no user, device, or service is trusted by default regardless of network location. Every request is explicitly authenticated and every action explicitly authorised. The design satisfies two standards simultaneously:

- **ISO 27001:2022** — risk-management approach used to determine controls above the baseline.
- **NCSA Minimum Security Standards** for public institutions — treated as the non-negotiable baseline.

## 2. Threat Model Summary

| Threat | Primary Control |
|--------|-----------------|
| Stolen access JWT | 15-minute TTL + refresh-token rotation + Redis revocation list |
| Stolen refresh token | HttpOnly Secure SameSite=Strict cookie; rotation on every use; per-jti revocation |
| Compromised pod | NetworkPolicy + read-only FS + non-root + seccomp + Vault dynamic creds |
| Compromised System Administrator | Append-only audit log with SHA-256 hash chain; Break Glass alerts |
| Database credential leak | Vault dynamic credentials, TTL 24 h |
| Malicious file upload | Sandbox node isolation; Cuckoo verdict before release |
| Insider abuse | Full audit trail; separation of duties via Supervised permissions |
| Supply-chain attack | Image digest pinning, cosign, Trivy CVE gate, Dependabot |
| DoS | Kong rate-limiting + HPA + circuit breakers + Squid allow-list |
| Lateral movement | Default-deny NetworkPolicy per namespace + per-schema DB grants |
| SSRF | Squid forward proxy with strict FQDN allow-list |

## 3. Zero-Trust Implementation (Six Mechanisms)

Zero-trust is implemented through six concrete, auditable mechanisms — not as marketing.

### 3.1 Explicit Identity Verification

Every request presents a verifiable identity.

| Principal | Credential |
|-----------|-----------|
| Human user | JWT issued after successful MFA |
| Backend service (internal API) | Service-account JWT |
| External integration | OAuth 2.0 token or mTLS certificate (NPKI) |

Kong validates human and external JWTs at the gateway boundary; service-to-service JWTs are re-validated at the receiving service's NestJS middleware (defence in depth).

### 3.2 Least Privilege Access

| Principal | Scope |
|-----------|-------|
| User role | Minimum permissions for the job function |
| Microservice DB account | Permissions only on schemas it owns + explicit SELECT grants for FK-able tables |
| Kubernetes pod | ServiceAccount with only the RBAC needed for its Secrets/ConfigMaps |
| External API credential | Scoped to minimum API permission set required by the integration |

### 3.3 Assume Breach

- NetworkPolicies prevent lateral movement — a compromised Registration Service **cannot query the Case Service's database directly**.
- The Sandbox zone assumes every uploaded file is potentially malicious until Cuckoo analysis proves otherwise.
- The immutable append-only audit log with SHA-256 hash chaining means even a compromised System Administrator cannot silently erase evidence.

### 3.4 Continuous Verification

- Sessions: 15-minute JWT access-token expiry requiring continuous refresh.
- Circuit breakers: sustained failure of an external dependency is treated as a potential compromise indicator.
- SIEM: continuously detects anomalous patterns in the audit log stream in real time.

### 3.5 Micro-Segmentation

- Kubernetes NetworkPolicies enforce pod-level traffic controls.
- The Sandbox zone has **no egress route** to the production data tier.
- The monitoring namespace can scrape metrics but cannot write to any database.

### 3.6 Data Encryption Everywhere

- In transit: TLS 1.3 (AEAD ciphers only).
- At rest: AES-256.
- Backups: AES-256 on backup volumes.
- Sensitive fields in logs (NIDA personal data): hashed before storage.

## 4. Defence in Depth — Five Layers

| Layer | Controls |
|-------|----------|
| **Network** | DMZ isolation, default-deny NetworkPolicies, Squid forward-proxy allow-list |
| **Transport** | TLS 1.3 with AEAD ciphers, mTLS for NPKI, HSTS 1-year |
| **API** | Kong JWT validation, rate limiting (sliding window), CSRF, Request Validator JSON Schema |
| **Application** | Service-level JWT re-validation, RBAC enforcement, circuit breakers, scope guards |
| **Data** | AES-256 at rest, Vault Transit envelope encryption, append-only audit log with hash chain |

## 5. Identity & Authentication

### 5.1 JWT Structure

```
Header  : { alg: "RS256", typ: "JWT" }
Payload : {
  sub:    "<user_id>",
  email:  "...",
  roles:  ["..."],
  jti:    "<unique-token-id>",   // revocation handle
  iat:    <epoch>,
  exp:    <epoch + 900>,         // 15 minutes
  iss:    "mis-dpo-rw"
}
Signature: RS256 over Header.Payload with 2048-bit RSA private key
```

**Why RS256, not HS256**: backend services hold only the **public key** (retrieved from `GET /api/v1/auth/jwks`). A compromised backend service cannot forge JWTs.

### 5.2 Token Storage

| Token | Storage | Why |
|-------|---------|-----|
| Access token (15 min) | JavaScript memory | Never `localStorage` or `sessionStorage` — XSS-resistant |
| Refresh token | HttpOnly Secure SameSite=Strict cookie | Prevents both XSS theft AND CSRF |

### 5.3 Validation Chain

```
Inbound request
   │
   ▼
Kong JWT plugin: signature, exp, aud, iss     ──── reject if invalid (HTTP 401)
   │
   ▼
Kong gRPC ValidateToken → Auth Service:
   - check jti against Redis revocation list
   - check session active
   - return claims
   │
   ▼
Kong injects X-User-ID, X-User-Roles, X-Request-ID
   │
   ▼
Target service: @mis/auth-middleware re-verifies signature (defence in depth)
```

### 5.4 Token Refresh & Rotation

The React app's Axios request interceptor automatically calls `POST /api/v1/auth/refresh` when the access token approaches expiry:

1. Auth Service validates refresh-token cookie.
2. Confirms `jti` exists in Redis (not revoked).
3. Generates new access + refresh tokens.
4. **Rotation**: old refresh `jti` is deleted from Redis and added to the revoked set.
5. Returns new access token; sets new refresh cookie.

This enables continuous sessions while ensuring stolen refresh tokens can be revoked.

### 5.5 Password Reset Flow

| Step | Behaviour |
|------|-----------|
| Generate | 32-byte cryptographically random reset token |
| Store | HMAC-SHA256 hash in `auth.users.password_reset_token`, 1-hour expiry |
| Send | Token (not the hash) emailed to `official_email` |
| Validate | Constant-time comparison against stored hash; check non-expiry and non-prior-use |
| Complexity | New password ≥ 12 chars, ≥1 upper, ≥1 lower, ≥1 digit, ≥1 special |
| Post-reset | **MFA re-enrolment required** — a password reset could indicate compromise |

### 5.6 MFA

- TOTP (preferred) or SMS fallback.
- `mfa_secret` AES-GCM encrypted at rest via Vault Transit.
- Required for all human accounts before first session.
- Re-enrolment forced after password reset.

### 5.7 NCSA HRMS LDAP

See [11 — External Integrations §8](./11-integrations.md#8-special-case-integrations) for the LDAP strategy, INTERNAL fallback, JIT provisioning, and nightly deprovisioning.

## 6. Authorization & RBAC Matrix

Claims-based permission model: **role membership** determines *what* operations a user can perform; **scope guards** determine *which records* those operations apply to.

### 6.1 Three Permission Types

| Type | Meaning |
|------|---------|
| **Standard** | Role grants the permission; user may execute directly |
| **Scoped** | Role grants the permission, but only on records matching a scope predicate (e.g. "applications assigned to me") |
| **Supervised** | Action requires second authorisation by a supervisor (separation of duties) |

### 6.2 Scope Guards

Implemented as middleware in `@mis/access-control`, injecting `WHERE` conditions into queries before execution:

```ts
@Patch(':id')
@RequirePermission('application:update')
@ScopeGuard({ entity: 'application', userField: 'assigned_officer_id' })
update(@Param('id') id: string, @Body() dto: UpdateApplicationDto) { /* ... */ }
```

Without the scope guard, a Registration Specialist could theoretically update any application; with it, they can update only their own assignments.

### 6.3 Supervised Permissions

Two-step workflow for actions requiring a second factor:

```
Officer initiates ──▶ PendingSupervisorAction in MongoDB
                      │
                      ▼
                  Supervisor WebSocket notification
                      │
                      ▼
                  Approve (with mandatory note) or Reject
                      │
              ┌───────┴────────┐
              ▼                ▼
        Admin Service       audit log
        executes action     (rejected reason)
```

Required for:

- Certificate revocation
- Enforcement action issuance
- Case closure with specific outcomes (configurable in Admin Console)

This prevents a rogue officer from unilaterally revoking certificates or issuing enforcement notices.

### 6.4 Break Glass

System Administrator may temporarily elevate their session for operational emergencies:

| Aspect | Value |
|--------|-------|
| Activation | Submits justification note (immediately written to audit trail) |
| Max duration | 4 hours |
| Alert | IT Security Administrator paged immediately |
| Audit | Every action during the elevated window tagged `break_glass=true` |
| Auto-revoke | Session de-escalates at expiry or on explicit revoke |

### 6.5 Public Routes

Documented allow-list bypasses Kong's JWT plugin via consumer group `public-routes`:

- `POST /api/auth/login`
- `POST /api/auth/refresh`
- `POST /portal/applications` (public form submission)
- `GET /registry/certificates/:id` (verify-only)
- `GET /api/v1/public/status/:ref_number`
- `GET /health`

Rate-limited at **20 req/min per IP** (vs 100 req/min authenticated).

## 7. Encryption Architecture

### 7.1 TLS at the Edge

Nginx in front of Kong (or Kong itself when TLS-terminated) is configured for **TLS 1.3 only** with AEAD cipher suites:

```
ssl_protocols              TLSv1.3;
ssl_ciphers                TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256;
ssl_prefer_server_ciphers  off;   # correct for TLS 1.3
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
```

RC4, DES, 3DES, and all export-grade cipher suites are explicitly disabled. `ssl_prefer_server_ciphers off` is correct for TLS 1.3 because cipher suite negotiation is encrypted within the handshake.

**HSTS**: `max-age=31536000` + `includeSubDomains`. The `preload` directive and HSTS preload-list submission follow after 6 months of stable production operation.

### 7.2 Encryption Matrix

| State | Where | Algorithm | Key Management | Notes |
|-------|-------|-----------|----------------|-------|
| **In transit (external)** | Client ↔ server, server ↔ external APIs | TLS 1.3 | cert-manager + Let's Encrypt OR NCSA internal CA; auto-renewal 30 d before expiry | TLS 1.2 and below disabled at the edge |
| **In transit (NPKI)** | Registration Service ↔ NPKI signing | mTLS (TLS 1.3 + client cert) | NPKI-issued MIS service cert in Vault; NPKI CA pinned | Client cert presented by Registration Service pod |
| **At rest: PostgreSQL** | Tables, indexes, WAL, pg_dump | AES-256 (LUKS / dm-crypt on PVs) | LUKS keys in Vault; injected to nodes at startup | Encrypts WAL + dump files |
| **At rest: MongoDB** | Collections, journal, backups | AES-256 (WiredTiger Encrypted Storage Engine) | Master key in Vault Transit; per-database keys wrapped by master | Backups encrypted before write |
| **At rest: Documents** | Uploaded files | AES-256-CBC, envelope encryption | Per-document DEK wrapped by Vault Transit KEK; encrypted DEK stored in MongoDB document record | KEK rotation without re-encrypting bodies |
| **At rest: backups** | All backup volumes | AES-256 | Separate KMS keys from runtime data | Geographic separation where required |
| **Audit-log integrity** | MongoDB `audit_logs` collection | SHA-256 hash chain | No key — cryptographic integrity, not confidentiality | Each entry stores SHA-256 of previous entry; chain verifiable from genesis |

### 7.3 Document Envelope Encryption Flow

The Document Service uses **Vault Transit** to perform envelope encryption without ever exposing plaintext key material to a database.

**Encryption**:

```
1. Document Service receives upload
2. Call POST /v1/transit/datakey/plaintext/documents-kek
   → response: { plaintext: "<DEK>", ciphertext: "vault:v3:<wrapped-DEK>" }
3. Encrypt document bytes with plaintext DEK (AES-256-CBC)
4. Persist:
   - encrypted document → object store
   - wrapped DEK ciphertext → MongoDB document record
5. Discard plaintext DEK from memory
```

**Decryption**:

```
1. Read wrapped DEK ciphertext from MongoDB
2. Call POST /v1/transit/decrypt/documents-kek with ciphertext
   → response: { plaintext: "<DEK>" }
3. Decrypt document bytes with plaintext DEK
4. Discard plaintext DEK from memory
```

At no point does any database record contain an unencrypted DEK.

### 7.4 KEK Rotation Without Re-encrypting Bodies

KEK rotation is **automated quarterly** using Vault Transit's `rewrap`:

```
1. Vault rotates documents-kek to a new version
2. On next document access:
   POST /v1/transit/rewrap/documents-kek with old-version ciphertext
   → response: { ciphertext: "vault:v4:<re-wrapped-DEK>" }
3. Replace the stored wrapped DEK in MongoDB
4. Document body never re-encrypted
```

A **background rewrap job** processes documents not accessed within 30 days, completing full KEK migration within the quarter following each rotation.

### 7.5 Key Rotation Schedule

| Key | Rotation | Mechanism |
|-----|----------|-----------|
| PostgreSQL LUKS | annual | Vault-distributed, node restart |
| MongoDB master key | quarterly | Vault Transit |
| Document KEK | quarterly | Vault Transit `rewrap` |
| JWT signing keypair | every 90 d | Ceremony; **15-minute overlap** during which both old and new are accepted (prevents session disruption) |
| TLS certs (edge) | 60 d | cert-manager + Let's Encrypt |
| TLS certs (internal) | 30 d | cert-manager + Vault PKI issuer |
| External API OAuth secrets | 90 d or on provider event | Vault KV v2 new version |
| Database dynamic credentials | 24 h | Vault Database engine |
| Sensitive field encryption | 180 d (rewrap) | Vault Transit |

## 8. Secrets Management — Vault

HashiCorp Vault OSS runs as a StatefulSet in `mis-infra` with a Raft-based HA backend (3 nodes).

### 8.1 Initialisation: Shamir's Secret Sharing

Vault is initialised with **Shamir's Secret Sharing**: 5 key shares, 3 required to unseal.

- Unseal keys distributed to NCSA custodians and stored separately.
- Vault is **never auto-unsealed** — that would create a single-point compromise.
- Unsealing on restart is a documented operational ceremony.

### 8.2 Pod Authentication

Pods authenticate via the **Vault Kubernetes auth method**:

```
Pod ServiceAccount JWT ─▶ Vault auth/kubernetes/login
                          │
                          ▼
                      Vault validates JWT against K8s API server
                          │
                          ▼
                      Returns Vault token scoped to the pod's policies
```

This eliminates static credential storage in Kubernetes Secrets.

### 8.3 Engines in Use

| Engine | Mount path | Purpose | Static / Dynamic |
|--------|-----------|---------|------------------|
| **KV v2** | `secret/` | Static application secrets (JWT signing keys, OAuth client IDs, API keys, NPKI cert + key) | Static, versioned |
| **Database** | `database/` | Dynamic PostgreSQL + MongoDB credentials | Dynamic, leased |
| **PKI** | `pki_internal/` | Internal TLS for service-to-service mTLS | Dynamic |
| **Transit** | `transit/` | Envelope encryption (documents, MongoDB master keys, sensitive fields) | Stateless |

### 8.4 KV v2 (Why and How)

KV v2 over KV v1 for:

| Capability | KV v1 | KV v2 |
|------------|:-----:|:-----:|
| Versioning | ✗ | ✓ |
| Soft delete / undelete | ✗ | ✓ |
| Check-and-set | ✗ | ✓ |
| Custom metadata | ✗ | ✓ |
| Per-version destroy | ✗ | ✓ |

Bootstrap once during cluster setup:

```bash
vault secrets enable -path=secret -version=2 kv
vault write secret/config max_versions=10 delete_version_after=720h
```

### 8.5 KV v2 Path Layout

```
secret/
└── mis/
    ├── auth/
    │   ├── jwt-signing             # current signing keypair (RS256)
    │   ├── jwt-previous            # previous keypair (15-min overlap window)
    │   ├── mfa-issuer              # TOTP issuer config
    │   ├── refresh-token-pepper    # HMAC pepper for refresh tokens
    │   └── ldap-bind               # NCSA HRMS LDAPS service-account bind
    ├── registration/
    │   ├── certificate-signer
    │   ├── public-portal
    │   ├── integrations/
    │   │   ├── rdb                 # { client_id, client_secret, token_url, base_url }
    │   │   ├── nida
    │   │   ├── rura
    │   │   ├── rgb
    │   │   ├── bnr
    │   │   └── rra
    │   └── npki/
    │       ├── client-cert
    │       └── client-key
    ├── case/
    │   └── webhook-signing
    ├── sandbox/
    │   └── scanner-api-keys
    ├── notification/
    │   ├── smtp
    │   ├── sms-provider
    │   └── webpush-vapid
    ├── reporting/
    │   ├── influxdb-token
    │   └── integrations/
    │       ├── rmb
    │       ├── moh
    │       └── nisr
    ├── document/
    │   └── s3
    ├── admin/
    │   └── notification-recipients
    └── shared/
        ├── kafka-sasl
        └── otel-collector-token
```

### 8.6 Policy (Per-Service)

Per-service policies are tight: each service reads its own subtree only.

```hcl
# policy: case-service
path "secret/data/mis/case/*"     { capabilities = ["read"] }
path "secret/metadata/mis/case/*" { capabilities = ["read", "list"] }
path "secret/data/mis/shared/*"   { capabilities = ["read"] }
path "database/creds/case-service-rw" { capabilities = ["read"] }
```

### 8.7 Secret Delivery to Pods

Vault Agent injector adds an init container plus a sidecar:

```yaml
metadata:
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: case-service

    # KV v2 (note `secret/data/` v2 path)
    vault.hashicorp.com/agent-inject-secret-jwt: "secret/data/mis/auth/jwt-signing"
    vault.hashicorp.com/agent-inject-template-jwt: |
      {{- with secret "secret/data/mis/auth/jwt-signing" -}}
      JWT_PUBLIC_KEY="{{ .Data.data.public_key }}"
      JWT_PRIVATE_KEY="{{ .Data.data.private_key }}"
      {{- end -}}

    # Dynamic DB credential (separate engine, no `data/` prefix)
    vault.hashicorp.com/agent-inject-secret-db: "database/creds/case-service-rw"
    vault.hashicorp.com/agent-inject-template-db: |
      {{- with secret "database/creds/case-service-rw" -}}
      DATABASE_URL="postgresql://{{ .Data.username }}:{{ .Data.password }}@pgbouncer.mis-production:6432/mis_core?pgbouncer=true"
      {{- end -}}
```

**KV v2 detail**: the API path is `secret/data/<path>` and the rendered template accesses fields via `.Data.data.<field>` (double `data`). `.Data` is the response envelope, `.Data.data` is the secret content, `.Data.metadata` holds version info. This is the single most common KV v2 mistake.

### 8.8 KV v2 Operations

```bash
vault kv put secret/mis/notification/smtp host=... port=587 user=... password=...
vault kv get -format=json secret/mis/notification/smtp
vault kv get -version=3 secret/mis/notification/smtp
vault kv rollback -version=2 secret/mis/notification/smtp     # bad rotation recovery
vault kv delete secret/mis/notification/smtp                   # soft-delete
vault kv undelete -versions=5 secret/mis/notification/smtp
```

### 8.9 Audit Devices

Vault file and syslog audit devices both enabled; audit logs ship to ELK as `mis-vault-audit-*`. Anomaly detection: a service reading another service's subtree, mass reads outside business hours, repeated `metadata/list` calls — these trigger SIEM alerts.

## 9. Network Security

### 9.1 Edge

- TLS 1.3 only at Nginx/Kong, AEAD cipher suites only, HSTS 1-year.
- Optional ModSecurity-OWASP CRS WAF plug-in on Kong.
- DDoS protection at upstream load-balancer / cloud provider.
- Public routes rate-limited (20 req/min/IP); authenticated routes 100 req/min/consumer.

### 9.2 East–West: Default Deny

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: mis-production
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
```

Applied to every namespace.

### 9.3 Allow-List Policies

```yaml
# Allow only Kong → service ingress
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-kong-to-case
  namespace: mis-production
spec:
  podSelector: { matchLabels: { app: case-service } }
  ingress:
    - from:
        - namespaceSelector: { matchLabels: { name: mis-infra } }
          podSelector: { matchLabels: { app: kong } }
      ports: [{ port: 3003, protocol: TCP }]
```

```yaml
# Allow service → DBs, Kafka, Redis, Vault, Squid
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-case-egress
  namespace: mis-production
spec:
  podSelector: { matchLabels: { app: case-service } }
  egress:
    - to: [{ podSelector: { matchLabels: { app: postgres } } }]
      ports: [{ port: 5432 }]
    - to: [{ podSelector: { matchLabels: { app: kafka } } }]
      ports: [{ port: 9092 }]
    - to: [{ podSelector: { matchLabels: { app: redis } } }]
      ports: [{ port: 6379 }]
    - to:
        - namespaceSelector: { matchLabels: { name: mis-infra } }
          podSelector: { matchLabels: { app: vault } }
      ports: [{ port: 8200 }]
    - to:
        - namespaceSelector: { matchLabels: { name: mis-infra } }
          podSelector: { matchLabels: { app: squid } }
      ports: [{ port: 3128 }]
    - to: [{ namespaceSelector: { matchLabels: { name: kube-system } } }]   # DNS
      ports: [{ port: 53, protocol: UDP }]
```

### 9.4 Namespace Egress Matrix

| Namespace | Ingress | Egress |
|-----------|---------|--------|
| `mis-production` | Only from Kong (`mis-infra`) | DBs, Kafka, Redis, Vault, DNS, Squid proxy |
| `mis-monitoring` | Scrape ports from all namespaces | Logging targets only; cannot write to any DB |
| `mis-sandbox` | Only Sandbox Service entrypoint | No internet; scan-result sinks only |
| `mis-infra` | Public via ingress for Kong only; Squid accepts from `mis-production` | Squid → internet for whitelisted external systems |
| `mis-staging` | Mirror of production rules | Mirror; WireMock stubs replace real external systems |

## 10. Egress Proxy (Squid)

All outbound traffic to external systems (RDB, NIDA, NPKI, RURA, RGB, BNR, RRA, RMB, MOH, NISR) flows through a Squid forward proxy in `mis-infra`. **Single internet egress point**.

```
Service pod ──▶ Squid (mis-infra) ──▶ Internet ──▶ External API
              [HTTP CONNECT, end-to-end TLS]
```

| Control | Behaviour |
|---------|-----------|
| Egress NetworkPolicy | Service pods may egress only to Squid (and cluster-internal targets); direct internet egress denied |
| Per-service FQDN allow-list | Squid ACL: e.g. `mis-registration-service` may reach `api.rdb.rw`, `api.nida.gov.rw`; others denied |
| TLS termination | None at Squid; uses `CONNECT` so TLS is end-to-end pod ↔ external API |
| Audit | Squid access log shipped to ELK as `mis-egress-*`; one line per outbound request |
| SSRF defence | Strict allow-list prevents requests to internal services or arbitrary external destinations (OWASP A10 control) |

**Exceptions**: NCSA HRMS uses LDAPS direct egress (TCP 636) with NetworkPolicy allow-list — no Squid.

See [11 — External Integrations §4](./11-integrations.md#4-outbound-proxy) for the operational view.

## 11. Pod & Workload Hardening

Standard pod security context applied to every service:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  runAsGroup: 10001
  fsGroup: 10001
  seccompProfile: { type: RuntimeDefault }
containers:
  - name: app
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: { drop: [ALL] }
```

PodSecurity admission set to `restricted` in `mis-production`, `mis-sandbox`, `mis-staging`.

## 12. Sandbox Isolation

The Sandbox Service runs untrusted submissions; it is the most constrained workload in the system.

| Layer | Control |
|-------|---------|
| Node | Dedicated nodes, taint `sandbox=true:NoSchedule` |
| Host firewall | Egress to internet **blocked** at iptables; only intra-cluster scan-result sinks reachable |
| Namespace | `mis-sandbox` with strict NetworkPolicy: zero egress to external CIDRs |
| Pod | `readOnlyRootFilesystem: true`, no privileged, drop ALL caps |
| Kernel | AppArmor profile restricting syscall surface |
| Filesystem | Ephemeral emptyDir, capped size |
| Submission | gRPC ingress from Document Service only |
| Verdict delivery | Kafka topic `mis.documents.verdict` (durable, at-least-once); `SandboxService.GetVerdict` gRPC remains as a reaper fallback |
| Progress delivery | Kafka topic `mis.documents.scan-progress` — per-stage UX events (`submitted` → `cuckoo` → `clamav` → `yara` → `suricata` → `aggregating` → `done`). Fire-and-forget; the Document Service updates `scan_stage` so polling reflects live progress |
| Cuckoo report storage | MongoDB collection `cuckoo_reports` in the `mis-sandbox` namespace replica set; sandbox-namespace SA is the only writer (see [schema.dbml](./schema.dbml) → `mongo.cuckoo_reports`) |
| Cuckoo runtime | Container `blacktop/cuckoo:2.0.7` in production; opt-in locally via `docker compose --profile cuckoo up cuckoo`. Sandbox Service talks to it via Cuckoo's REST API on `:8090`; falls back to an in-process deterministic mock when `CUCKOO_URL` is unset (e.g. on a host without `/dev/kvm`) |

### 12.1 Quarantine-first workflow

Every upload is held in a **quarantine** bucket and is only promoted to the canonical, envelope-encrypted store **after** the Sandbox returns `SAFE`. A malicious blob therefore never lands in production storage. See [document-upload-workflow.md](./document-upload-workflow.md) for the full end-to-end sequence; the high-level shape is:

```
Client ─► Kong ─► Document Service
                       │
                       │ (1) hash + pre-flight checks
                       │ (2) stream bytes ─► quarantine S3   (NOT envelope-encrypted)
                       │ (3) insert document row, status=PENDING_SCAN
                       │ (4) 202 Accepted to client
                       ▼
              Sandbox Service ─ gRPC stream from Document only
                       │
                       ▼  (ephemeral pod on tainted sandbox node)
              Cuckoo + ClamAV + YARA + Suricata  (parallel fan-out)
                       │
                       │ persist full report → mongo.cuckoo_reports
                       ▼
        Kafka mis.documents.verdict  (verdict + per-scanner detail)
                       │
                       ▼
              Document Service consumer
                       │
        ┌──────────────┼──────────────┐
        ▼              ▼              ▼
      SAFE        SUSPICIOUS       MALICIOUS
        │              │              │
        │              │              ├─► append SHA-256 to bad-hash blocklist
        │              │              ├─► move blob → mis-documents-forensics (legal hold)
        │              │              ├─► UPDATE doc_status=BLOCKED, sandbox_classification=MALICIOUS
        │              │              ├─► Kafka mis.notifications (EMAIL to submitter + page security)
        │              │              └─► hash-chained audit event (SEV-1)
        │              │
        │              └─► UPDATE doc_status=QUARANTINED, open review ticket (Admin Service)
        │
        ├─► Vault Transit datakey/plaintext/documents-kek
        ├─► AES-256-CBC(DEK, bytes) → canonical bucket
        ├─► persist wrapped DEK on document row, doc_status=ACTIVE
        └─► delete quarantine blob
```

### 12.2 Persisting the Cuckoo report

The Sandbox Service writes the full per-submission report to MongoDB **before** publishing the verdict, so every consumer (Document Service, Admin Service auditors, IR analysts) can fetch the evidence by `cuckoo_task_id`. The collection is defined in [schema.dbml](./schema.dbml):

| Field | Source |
|-------|--------|
| `cuckoo_task_id` | Cuckoo's per-submission task identifier (also stamped on `mongo.documents.cuckoo_task_id` so a document row joins to its report) |
| `document_id` | Echoed from `SubmissionMetadata.document_id` |
| `submitted_at` / `completed_at` | Sandbox bookends |
| `classification` | `SAFE \| SUSPICIOUS \| MALICIOUS` |
| `signatures` | Cuckoo signature hits (JSON array) |
| `network_iocs` | Aggregated from Cuckoo PCAP analysis + Suricata alerts |
| `file_iocs` | Dropped-file hashes, registry writes, mutexes |
| `raw_report` | Full Cuckoo JSON, 1–10 MB typical — retained for forensics |

The `documents` collection (owned by the Document Service) carries the **verdict summary**: `sandbox_classification`, `cuckoo_task_id`, `clamav_result`, `yara_matches[]`, `suricata_alerts[]`. That keeps the hot read path (status checks, listings) cheap, while the heavy raw report stays in the sandbox-namespace collection behind a stricter access boundary.

### 12.3 Notifying the submitter on a MALICIOUS verdict

The Document Service emits a `mis.notifications` event (channel `EMAIL`, template `document-rejected-malicious`) which the Notification Service renders and sends via SMTP. The body is **sanitised** — it never reveals scanner IOCs, only that the file failed security checks and how to contact support.

| Environment | SMTP target |
|-------------|-------------|
| Local dev | **MailDev** (`maildev:1025` from inside Compose, `localhost:1025` from the host); inspect captured mail at `http://localhost:1080` |
| Staging / Prod | Tenant SMTP relay; credentials in `secret/notification/smtp` (Vault KV v2) |

MailDev is wired into `mis-dev/docker/docker-compose.yml` so the malicious-path flow can be exercised end-to-end on a laptop without any outbound email leaving the network. See [document-upload-workflow.md §8](./document-upload-workflow.md#8-post-verdict-actions) for the full notification payload and case-timeline write-back.

## 13. Auditing & Tamper-Evidence

### 13.1 What is Audited

Every auditable action flows through `@mis/audit-logger` → Kafka `mis.audit` → Admin Service → MongoDB `audit_logs` (and `mis-audit-*` Elasticsearch index for query).

Audited events:

- All authentication outcomes (success, failure, MFA challenge)
- All resource mutations (create, update, delete)
- All permission grants/revocations
- All admin actions
- All file submissions and Sandbox verdicts
- All exports / reports generated
- All Break Glass activations
- All Supervised-permission approvals and rejections
- All external API calls

### 13.2 Hash-Chain Tamper-Evidence

Each `audit_logs` entry stores:

- `prev_entry_hash` — SHA-256 of the previous entry's content
- `entry_hash` — SHA-256 of this entry's content

```
Entry n-1                  Entry n                   Entry n+1
┌─────────────┐           ┌─────────────┐           ┌─────────────┐
│ content     │  SHA-256  │ content     │  SHA-256  │ content     │
│ entry_hash  │◀──────────│ prev_hash   │◀──────────│ prev_hash   │
└─────────────┘           │ entry_hash  │           │ entry_hash  │
                          └─────────────┘           └─────────────┘
```

The Admin Service runs a **nightly chain verification job**: walks the latest 24 h of entries, recomputes hashes, asserts each `prev_entry_hash` matches the predecessor's `entry_hash`. Any mismatch raises a SEV-1 alert.

Combined with MongoDB role permissions (write-only for `audit-writer`, read-only for `auditor`, **no update/delete**) and `$jsonSchema` validators, the log is tamper-evident in practice. Forensic auditors can export and externally re-verify the chain from genesis.

### 13.3 Retention & Immutability

- Elasticsearch ILM: rollover, read-only after 1 day.
- Index-level access: write only by Admin Service SA; read by Auditor role.
- MongoDB `audit_logs` TTL: 5 years (157 680 000 s) before automatic expiry.
- Archive to WORM-style object store before TTL where legal retention exceeds 5 years.

## 14. Supply Chain Security

| Stage | Control |
|-------|---------|
| Source | Branch protection, required reviews, signed commits |
| Dependencies | `npm audit` + Dependabot; CI gate on High/Critical CVEs |
| Build | Hermetic Docker builds, pinned base images, **digest pinning** (not just tags) |
| Image signing | cosign with key in Vault Transit; ArgoCD verifies signatures |
| SBOM | Generated at build (Syft) and stored alongside image |
| Registry | Internal Azure Container Registry, Trivy scan on push |
| Drift | ArgoCD drift detection — any out-of-band change to cluster is detected and reverted |
| Runtime | Read-only FS, drop caps, seccomp |
| Helm provenance | Chart provenance verification before deploy |

ArgoCD admission refuses to apply a Deployment whose image is **unsigned** or whose tag has unresolved **High/Critical** CVEs.

## 15. OWASP Top 10 Control Mapping

Required by the ToR.

| OWASP Top 10 (2021) | MIS Control |
|---------------------|-------------|
| **A01 Broken Access Control** | RBAC at Kong consumer groups + service middleware; database service accounts scoped to minimum schemas; scope guards in `@mis/access-control` |
| **A02 Cryptographic Failures (Sensitive Data Exposure)** | AES-256 at rest, TLS 1.3 in transit, envelope encryption for documents, no PII in logs/error messages |
| **A03 Injection** | Prisma ORM parameterised queries; Kong JSON Schema request validation; Zod validation in services |
| **A04 Insecure Design** | Threat-modelled architecture, separation of duties (Supervised permissions), Break Glass with audit |
| **A05 Security Misconfiguration** | IaC (Terraform + Helm); CIS Kubernetes Benchmark scanning; Trivy image + IaC scanning; default-deny everywhere |
| **A06 Vulnerable & Outdated Components** | Trivy CVE scan blocks High/Critical in CI; Dependabot PRs; monthly base image refresh |
| **A07 Identification & Authentication Failures** | JWT RS256, 15-min access TTL, MFA, account lockout after N failures, HttpOnly Secure cookie refresh tokens, refresh rotation |
| **A08 Software & Data Integrity Failures** | Docker image **digest pinning**, cosign signatures, Helm chart provenance, ArgoCD drift detection |
| **A09 Security Logging & Monitoring Failures** | Comprehensive audit log, hash-chain tamper-evidence, SIEM real-time monitoring, runbook-linked alerts |
| **A10 SSRF** | Squid forward proxy with strict FQDN allow-list — prevents SSRF to internal services or arbitrary destinations |

## 16. Compliance & Validation

### 16.1 Automated Validation (Continuous)

| Check | Tool | Frequency |
|-------|------|-----------|
| Kubernetes CIS Benchmark | `kube-bench` | CI + nightly |
| NetworkPolicy enforcement | `kubectl-netpol-verify` | CI |
| Container CVE scan | Trivy | Per build + nightly registry sweep |
| IaC misconfig scan | Trivy IaC + kube-linter | CI on `mis-config` |
| SAST | Semgrep | CI |
| Secrets in source | Gitleaks | CI |
| Vault audit anomalies | SIEM rules on `mis-vault-audit-*` | Real-time |

### 16.2 Quarterly Manual Validation Script

The IT Security Administrator attempts defined cross-boundary connection attempts that **should be denied**. Any success is a NetworkPolicy regression requiring immediate remediation.

| # | From | To | Expected |
|---|------|-----|----------|
| 1 | Case Service pod | Registration Service's PostgreSQL DB | **Denied** |
| 2 | Sandbox (Cuckoo master) pod | MongoDB primary | **Denied** |
| 3 | Notification Service pod | Kong Admin API | **Denied** |
| 4 | Outside cluster | Backend microservice port bypassing Kong | **Denied** |
| 5 | Registration Service pod | arbitrary internet host not in Squid allow-list | **Denied** |
| 6 | Monitoring namespace pod | Any database write | **Denied** |

The script is checked into `mis-config/security/quarterly-validation/` and runs as a Job with results posted to Slack and filed as evidence for ISO 27001 audit.

### 16.3 Standards Coverage

| Requirement | Coverage |
|-------------|----------|
| ISO 27001:2022 — risk-based control selection | This architecture |
| NCSA Minimum Security Standards | Baseline; non-negotiable |
| Law No. 058/2021 (Data Protection) | Operational controls + audit trail + retention |
| OWASP Top 10 (2021) | §15 mapping above |
| CIS Kubernetes Benchmark | `kube-bench` continuous check |

## 17. Incident Response

| Severity | Response time | Comms |
|----------|---------------|-------|
| SEV-1 (outage, data exposure, audit chain break) | < 15 min | War room, status page, leadership |
| SEV-2 (degradation, integration outage, Break Glass) | < 1 h | Slack incident channel |
| SEV-3 (limited impact) | < 4 h | Ticket + Slack |

Runbooks in `mis-config/runbooks/`. Postmortems are blameless and required within 5 business days of any SEV-1/2.

### Key Playbooks

| Scenario | Action |
|----------|--------|
| **JWT signing key leak** | Rotate signing key (write new version to `secret/mis/auth/jwt-signing`); old version retained 15 min then destroyed; force re-login |
| **Refresh-token leak** | Invalidate `jti` in Redis; force re-login for affected user(s) |
| **DB compromise** | Vault revoke dynamic creds; snapshot; isolate; restore to clean cluster from PITR |
| **Sandbox escape suspected** | Cordon sandbox node; snapshot disk; evict pods; forensics |
| **DLQ flood** | Admin Service dashboard; root-cause consumer; replay with fixed handler |
| **Audit hash-chain break** | SEV-1; freeze writes to `audit_logs`; forensic export; identify last good entry; investigate insertion path |
| **Break Glass activation** | Auto-alert to IT Security Admin; observer attaches to session; full audit of elevated actions |
| **External integration prolonged outage** | Officer queue absorbs `MANUAL_REVIEW_REQUIRED`; SIEM tracks circuit-state duration; escalation to external operator per integration runbook |
| **Squid allow-list breach attempt** | Squid logs already capture; SIEM alert on repeated denies from same source |
