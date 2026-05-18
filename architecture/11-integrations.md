# 11 — External Integrations

## Table of Contents

1. [Scope](#1-scope)
2. [Integration Inventory](#2-integration-inventory)
3. [Standard Integration Pattern](#3-standard-integration-pattern)
4. [Outbound Proxy](#4-outbound-proxy)
5. [Authentication Patterns](#5-authentication-patterns)
6. [Result States & Officer Workflow](#6-result-states--officer-workflow)
7. [Parallel Execution & Sector Routing](#7-parallel-execution--sector-routing)
8. [Special-Case Integrations](#8-special-case-integrations)
9. [Monitoring & Staging](#9-monitoring--staging)
10. [Per-Integration Implementation Notes](#10-per-integration-implementation-notes)

---

## 1. Scope

MIS connects to 11 external systems. Most are sector-conditional verifications fired during application processing; a few are platform integrations (identity, signing, public portal). All outbound calls follow the same resilience pattern so an operator only has to learn it once.

## 2. Integration Inventory

| # | System | Owner Service | Purpose | When Called |
|---|--------|---------------|---------|-------------|
| 1 | **RDB** Business Registry | Registration | Verify business registration | On email-verification confirmation |
| 2 | **NIDA** National ID | Registration | Verify DPO identity + ≥18 age | Parallel with RDB |
| 3 | **NPKI** Digital Signing | Registration | Sign certificate PDFs | On certificate issuance |
| 4 | **NCSA HRMS** LDAP | Auth | Staff authentication + role mapping | Every staff login |
| 5 | **RURA** Utilities | Registration | Sector check (UTILITIES, TELECOM) | Sector-conditional |
| 6 | **RGB** Governance Board | Registration | Sector check (NGO, CIVIL_SOCIETY, GOVERNANCE) | Sector-conditional |
| 7 | **BNR** Central Bank | Registration | Sector check (BANKING, INSURANCE, MICROFINANCE) | Sector-conditional |
| 8 | **RRA** Tax Authority | Registration | TIN cross-check for all commercial entities | Always (commercial) |
| 9 | **RMB** Mining Board | Reporting | Sector check (MINING, MINERALS) | Sector-conditional |
| 10 | **MOH** Ministry of Health | Reporting | Sector check (HEALTH, PHARMACEUTICAL) | Sector-conditional |
| 11 | **NISR** Statistics | Reporting | Sector check (STATISTICS, RESEARCH, SURVEY) | Sector-conditional |

Also covered in this doc: the **Public Portal** API surface, which is internal but is the *inbound* counterpart to most of the above.

## 3. Standard Integration Pattern

Every integration is implemented as a NestJS provider that subclasses a common `ExternalIntegrationClient` from `@mis/circuit-breaker`, giving identical behaviour for retries, breaker, fallback, metrics, and audit.

```ts
// Pseudo-shape — actual classes live in the owning service
@Injectable()
export class RdbClient extends ExternalIntegrationClient {
  protected name = 'rdb';
  protected baseUrl = process.env.RDB_BASE_URL!;

  async verify(rdbNumber: string, name: string): Promise<VerificationResult> {
    return this.callJson({
      method: 'GET',
      path: '/api/v1/entities',
      query: { registration_number: rdbNumber, name },
      // standard breaker config below applied automatically
    });
  }
}
```

### Standard configuration (every integration unless noted)

| Setting | Value |
|---------|-------|
| Transport | HTTPS, TLS 1.3 |
| Outbound | Via **Squid forward proxy** (single egress point) |
| Retries | 3, exponential backoff 1 s / 2 s / 4 s |
| Timeout | 10 000 ms per attempt |
| Circuit breaker (opossum) | `volumeThreshold=5`, `errorThresholdPercentage=50`, `resetTimeout=60000` |
| On open | Set result → `MANUAL_REVIEW_REQUIRED`, emit Kafka event, **never block application** |
| Audit | Every call logged via `@mis/audit-logger` (action `EXTERNAL_API_CALL`) |
| Metrics | Standard set from `@mis/metrics` + integration-specific labels |

> **Universal rule**: an external system being down must never block a citizen-facing or applicant-facing flow. The fallback is always *flag for officer*, *continue the process*.

## 4. Outbound Proxy

```
Service pod ──▶ Squid forward proxy (mis-infra) ──▶ Internet ──▶ External API
```

- Single egress point; only Squid has internet egress from `mis-production`.
- NetworkPolicy denies direct internet egress to all service pods.
- Squid enforces an allow-list of FQDNs per service (e.g. only `mis-registration-service` may reach `api.rdb.rw`).
- TLS originates at the service pod (end-to-end TLS through `CONNECT`). Squid does not terminate.
- Audit access log shipped to ELK as `mis-egress-*`.

## 5. Authentication Patterns

| Pattern | Used by | Notes |
|---------|---------|-------|
| **OAuth 2.0 Client Credentials** | RDB, NIDA, RURA, RGB, BNR, RRA, RMB, MOH, NISR | Client ID + secret in Vault KV v2; token cached in Redis at `token:<system>` with TTL = expiry − 60 s; auto-refresh |
| **mTLS** | NPKI | Service certificate + private key in Vault; NPKI root CA pinned in TLS config |
| **LDAP BIND over LDAPS** | NCSA HRMS | Service-account bind, password validated by LDAP BIND of user DN |

Cached token structure in Redis:

```
KEY: token:rdb            TYPE: String(JSON)  TTL: <expiry - 60s>
  VALUE: { access_token, token_type, expires_at, scope }
```

Token refresh is **single-flight**: a Redis `SET NX` lock at `lock:token-refresh:{system}` prevents thundering-herd refreshes when multiple pods see expiry simultaneously.

## 6. Result States & Officer Workflow

Every sector verification produces one of:

| Result | Meaning | Effect on application |
|--------|---------|-----------------------|
| `VERIFIED` | Active and matched | Auto-progress |
| `VERIFIED` + flag | Matched with caveat (`provisional_flag`, `name_mismatch_flag`, `partial_licence_flag`) | Officer adjudicates |
| `INCONCLUSIVE` | Ambiguous data (in-progress, lapsed, mismatched category) | Officer reviews |
| `INACTIVE` | Known but not active | Officer reviews |
| `NOT_FOUND` | No record | Officer reviews |
| `MISMATCH` | Record exists but disagrees | Officer reviews |
| `MANUAL_REVIEW_REQUIRED` | Circuit open or all retries exhausted | Officer reviews; integration health alert |

When result ≠ `VERIFIED`, the application moves to the officer queue with the integration name and result attached. The integration monitoring dashboard (see §9) is the first stop when a manual-review flag appears.

## 7. Parallel Execution & Sector Routing

All applicable verifications run **in parallel** via `Promise.allSettled` so total verification latency equals the slowest call, not the sum.

```ts
const verifications = await Promise.allSettled([
  this.rdb.verify(app.rdbNumber, app.legalName),
  this.nida.verify(app.dpoNidaRef),
  ...this.sectorClients(app.sector).map(c => c.verify(app)),
]);
```

### Sector → integration mapping

| Declared sector | Always | Sector-specific |
|-----------------|--------|-----------------|
| `BANKING` / `INSURANCE` / `MICROFINANCE` / `FINANCIAL_SERVICES` | RDB, NIDA, RRA | BNR |
| `UTILITIES` / `TELECOMMUNICATIONS` | RDB, NIDA, RRA | RURA |
| `NGO` / `CIVIL_SOCIETY` / `GOVERNANCE` | RDB, NIDA, RRA | RGB |
| `MINING` / `MINERALS` | RDB, NIDA, RRA | RMB |
| `HEALTH` / `PHARMACEUTICAL` | RDB, NIDA, RRA | MOH |
| `STATISTICS` / `RESEARCH` / `SURVEY` | RDB, NIDA, RRA | NISR |
| Other commercial | RDB, NIDA, RRA | — |
| Non-commercial / public | RDB, NIDA | RRA optional |

Sector→client routing is implemented as a registry pattern; adding a sector mapping is a config change.

## 8. Special-Case Integrations

Most integrations follow the same shape. These four deviate.

### NPKI (Digital Signing)

- **mTLS** instead of OAuth; service cert in Vault, NPKI CA pinned.
- **No silent fallback** — manual unsigned certificates are not permitted (legal requirement).
- On unavailability: certificate issuance queued in **Redis sorted set** with retry every 5 min; officer notified via WebSocket.

Flow:
```
1. Generate PDF (PDFKit)
2. SHA-256 of PDF bytes
3. POST hash + officer signer_ref + PIN to NPKI
4. Receive PKCS#7 signature
5. Embed via pdf-lib (ISO 32000-2 incremental save)
6. Store signed PDF in Document Service
```

### NCSA HRMS (LDAP)

- **LDAPS** on port 636; not REST.
- LDAP group → MIS role mapping stored as **JSON config in MongoDB**, editable via Admin Console.
- Multiple groups → union of mapped roles.
- **Strategy pattern fallback to INTERNAL auth** (bcrypt against `auth.users`) via config flag, no code change required.
- Nightly **deprovisioning sweep**: disabled LDAP accounts → MIS account deactivation within 24 h.
- **Just-in-time provisioning**: `auth.users` row created on first successful LDAP login.

### NIDA (Identity)

- **Data minimisation**: DOB used only for ≥18 age check, then discarded.
- Personal details stored in encrypted temporary field, **purged after 90 days** by retention job.
- DPO target for Controllers; authorised representative for Processors.
- **SDID upgrade path**: LDAP adapter → OIDC adapter via `NIDA_ADAPTER_TYPE` feature flag, no code deploy.

### RDB (Business Registry)

- **Fuzzy name matching** (Levenshtein, threshold configurable in Admin Console) for trading name vs legal name; close match → `VERIFIED` + `name_mismatch_flag`.
- `IN_PROGRESS` status → `INCONCLUSIVE` (new businesses registering simultaneously).

## 9. Monitoring & Staging

### Integration monitoring dashboard (Grafana)

One row per integration showing:

| Panel | Source | Alert |
|-------|--------|-------|
| Request volume (last 30 min) | Prometheus counter `external_request_total{system}` | — |
| Error rate (last 30 min) | Counter ratio | **Red when > 5 %** |
| Circuit breaker state | Gauge `circuit_breaker_state{target}` | **Badge red when open** |
| Last state-change timestamp + triggering error count | From CB state transitions | — |
| Average latency on success | Histogram p50/p95 | — |

This is the first reference when an officer sees `MANUAL_REVIEW_REQUIRED` — it tells them whether the integration is recovering or needs escalation to the external operator.

### Staging stubs

Every integration has a **WireMock** stub in `mis-staging` returning deterministic responses based on test-entity reference prefixes:

| Prefix | Response |
|--------|----------|
| `TEST-OK-*` | `VERIFIED` |
| `TEST-NF-*` | `NOT_FOUND` |
| `TEST-IN-*` | `INACTIVE` |
| `TEST-ERR-*` | HTTP 500 (drives circuit breaker tests) |

WireMock instances live in `mis-staging`; in `mis-production`, `EXTERNAL_<SYSTEM>_BASE_URL` points to the real endpoint.

## 10. Per-Integration Implementation Notes

These deltas summarise what's unique per integration. For full spec, see SRS §5.2–5.13.

### RDB
- Endpoint: `GET /api/v1/entities?registration_number=&name=`
- Auth: OAuth CC
- Special: Levenshtein fuzzy name match; `IN_PROGRESS` → `INCONCLUSIVE`

### NIDA
- Endpoint: TBD per SDID rollout
- Auth: LDAP today, OIDC after SDID
- Special: age check ≥ 18; DOB discarded; 90-day purge of personal details

### NPKI
- Auth: mTLS
- Special: No unsigned fallback; queued retries via Redis ZSET

### NCSA HRMS
- Protocol: LDAPS (port 636)
- Special: JSON role mapping in Mongo; INTERNAL fallback strategy; JIT provisioning; nightly deprovision sweep

### RURA
- Endpoint: `GET /api/v1/entities?registration_number=&sector=`
- Sectors: `UTILITIES`, `TELECOMMUNICATIONS`
- Special: Provisional auth → `VERIFIED` + `provisional_flag`

### RGB
- Endpoint: `GET /api/v1/entities?registration_number=`
- Sectors: `NGO`, `CIVIL_SOCIETY`, `GOVERNANCE`
- Special: Suspended status → `INACTIVE`; fuzzy match on re-registration

### BNR
- Endpoint: `GET /api/v1/institutions?registration_number=&institution_type=`
- Sectors: `BANKING`, `INSURANCE`, `MICROFINANCE`, `FINANCIAL_SERVICES`
- Special: BNR category vs declared sector mismatch → flag, do not block

### RRA
- Endpoint: `GET /api/v1/taxpayers?tin=&legal_name=`
- Sectors: All commercial entities
- Special: Same Levenshtein fuzzy match as RDB; inactive TIN → `INACTIVE`

### RMB (owned by Reporting Service)
- Endpoint: `GET /api/v1/licensees?licence_number=`
- Sectors: `MINING`, `MINERALS`
- Special: Multi-licence entities → `VERIFIED` if ≥1 active, with `partial_licence_flag`

### MOH (owned by Reporting Service)
- Endpoint: `GET /api/v1/health-entities?registration_number=`
- Sectors: `HEALTH`, `PHARMACEUTICAL`
- Special: National and district registration both supported; lapsed-but-not-revoked → `INCONCLUSIVE`

### NISR (owned by Reporting Service)
- Endpoint: `GET /api/v1/entities?registration_number=`
- Sectors: `STATISTICS`, `RESEARCH`, `SURVEY`
- Special: Time-limited survey auth → `VERIFIED` + `authorisation_expiry`; unregistered legitimate research → `NOT_FOUND` flag without block

---

### Cross-reference

- Outbound resilience and breaker semantics: [03 — Service Communication §6](./03-service-communication.md#6-circuit-breaker-pattern)
- Squid egress + NetworkPolicies: [08 — Security §9–§10](./08-security.md#9-network-security)
- OAuth secrets and Vault paths: [08 — Security §8](./08-security.md#8-secrets-management--vault)
- Dashboard panels: [07 — Observability §3](./07-observability.md#3-dashboards--grafana)
