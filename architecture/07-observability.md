# 07 — Observability

## Table of Contents

1. [The Three Pillars](#1-the-three-pillars)
2. [Metrics — Prometheus](#2-metrics--prometheus)
3. [Dashboards — Grafana](#3-dashboards--grafana)
4. [Tracing — Jaeger](#4-tracing--jaeger)
5. [Logs — ELK Stack](#5-logs--elk-stack)
6. [Correlation Across Pillars](#6-correlation-across-pillars)
7. [Alerting](#7-alerting)
8. [SLOs](#8-slos)

---

## 1. The Three Pillars

```
                  ┌──────────── Observability Plane (mis-monitoring) ────────────┐
                  │                                                              │
   Services ──▶ Prometheus ────▶ Grafana       (metrics)                          │
   Services ──▶ Jaeger Agent ──▶ Jaeger        (traces)                           │
   Services ──▶ Filebeat ─────▶ Logstash ─▶ Elasticsearch ─▶ Kibana (logs)        │
                  │                                                              │
                  └──────────────────────────────────────────────────────────────┘
```

All pillars share a common correlation identifier: `X-Request-ID` (also surfaced as the `correlation_id` field in logs and the `mis.request.id` span attribute in traces).

## 2. Metrics — Prometheus

### Deployment

- Prometheus Operator in `mis-monitoring`
- HA: two Prometheus replicas, each scraping independently
- Long-term storage: remote write to Thanos / Cortex (optional)
- Service discovery: `ServiceMonitor` CRDs created by each Helm chart

### What is scraped

| Source | Endpoint | Metrics |
|--------|----------|---------|
| Each service | `:9090/metrics` (internal) | `@mis/metrics` standard set |
| Kong | `:8001/metrics` | RPS, latency, status codes |
| Kafka (Strimzi) | JMX exporter | Broker, topic, consumer-lag |
| PostgreSQL | postgres_exporter | Connections, replication lag, locks |
| MongoDB | mongodb_exporter | Replication, opcounters |
| InfluxDB | built-in | Series cardinality, query duration |
| Redis | redis_exporter | Memory, ops/sec, hit rate |
| Node | node_exporter | CPU, memory, disk, network |
| Kubernetes | kube-state-metrics, cAdvisor | Pod restarts, container resources |

### Standard application metric set (from `@mis/metrics`)

| Metric | Type | Labels |
|--------|------|--------|
| `http_request_duration_seconds` | Histogram | `route`, `method`, `status`, `service` |
| `http_requests_total` | Counter | `route`, `method`, `status`, `service` |
| `http_active_connections` | Gauge | `service` |
| `db_query_duration_seconds` | Histogram | `operation`, `entity`, `service` |
| `kafka_producer_messages_total` | Counter | `topic`, `result`, `service` |
| `kafka_consumer_lag` | Gauge | `topic`, `partition`, `consumer_group` |
| `circuit_breaker_state` | Gauge | `target`, `service` (0=closed, 1=half, 2=open) |
| `external_request_total` | Counter | `system`, `result` (success / error / timeout), `service` |
| `external_request_duration_seconds` | Histogram | `system`, `service` |
| `nodejs_eventloop_lag_seconds` | Gauge | `service` |

### Recording rule examples

```yaml
groups:
  - name: mis.sli
    rules:
      - record: mis:http_request_rate_5m
        expr: sum by (service, route) (rate(http_requests_total[5m]))

      - record: mis:http_error_ratio_5m
        expr: |
          sum by (service) (rate(http_requests_total{status=~"5.."}[5m]))
          /
          sum by (service) (rate(http_requests_total[5m]))

      - record: mis:http_latency_p99_5m
        expr: |
          histogram_quantile(
            0.99,
            sum by (service, le) (rate(http_request_duration_seconds_bucket[5m]))
          )
```

## 3. Dashboards — Grafana

Dashboard catalogue (one folder per audience):

| Folder | Dashboards |
|--------|------------|
| Platform | Cluster overview, Node health, etcd, ArgoCD sync state |
| Service | Per-service: RPS, error rate, p50/p95/p99, DB latency, breaker state |
| Kafka | Topic throughput, consumer lag, DLQ depth |
| Business | Cases opened/closed, SLA breaches, applications by status |
| Security | Auth failures, rate-limit rejections, Vault audit anomalies |
| **Integrations** | **One row per external system: volume, error rate, breaker state, latency** |

Each per-service dashboard follows the RED method (Rate / Errors / Duration) plus saturation.

### Integration Monitoring Dashboard

A dedicated single-pane-of-glass for the 11 external integrations (RDB, NIDA, NPKI, NCSA HRMS, RURA, RGB, BNR, RRA, RMB, MOH, NISR). One row per integration with five panels:

| Panel | Metric | Source | Threshold |
|-------|--------|--------|-----------|
| Request volume (30 min) | `sum(rate(external_request_total{system="$s"}[30m])) * 1800` | Counter | — |
| Error rate (30 min) | `sum(rate(external_request_total{system="$s",result="error"}[30m])) / sum(rate(external_request_total{system="$s"}[30m]))` | Counter ratio | **Red when > 5 %** |
| Circuit breaker state | `circuit_breaker_state{target="$s"}` | Gauge (0=closed, 1=half, 2=open) | **Red badge when = 2** |
| Last state change | Annotation from state-transition events | — | Timestamp + triggering error count |
| Avg latency (success) | `histogram_quantile(0.5, ...)` and p95 | Histogram | — |

This dashboard is the **first reference when an officer sees a `MANUAL_REVIEW_REQUIRED` flag** in the queue — it tells the operator immediately whether the integration is recovering or whether an escalation to the external system operator is warranted. Linked from the officer UI's manual-review badge.

Alert rules (Alertmanager):

```yaml
- alert: IntegrationErrorRateHigh
  expr: |
    sum by (system) (rate(external_request_total{result="error"}[30m]))
    /
    sum by (system) (rate(external_request_total[30m])) > 0.05
  for: 5m
  labels: { severity: warning }

- alert: IntegrationCircuitOpen
  expr: circuit_breaker_state{target=~"rdb|nida|npki|rura|rgb|bnr|rra|rmb|moh|nisr"} == 2
  for: 2m
  labels: { severity: warning }
  annotations:
    summary: "{{ $labels.target }} circuit breaker is OPEN"
    runbook: "https://docs.mis.example.org/runbooks/integration-{{ $labels.target }}"
```

See [11 — External Integrations](./11-integrations.md) for the integration design.

### Example panel queries

```promql
# RPS by route
sum by (route) (rate(http_requests_total{service="case-service"}[1m]))

# Error rate %
mis:http_error_ratio_5m{service="case-service"} * 100

# p99 latency
mis:http_latency_p99_5m{service="case-service"}

# Kafka consumer lag
max by (topic, consumer_group) (kafka_consumer_lag)
```

## 4. Tracing — Jaeger

### Pipeline

```
Service (OTel SDK) → OTel Collector (DaemonSet) → Jaeger Collector → Cassandra/Elasticsearch backend → Jaeger Query UI
```

- Each NestJS service auto-instruments HTTP, gRPC, Kafka, Postgres, Mongo, Redis via OpenTelemetry SDK.
- Kong OTel plugin generates root spans on every inbound request.
- Sampling: head-based 10 % default, **100 %** for requests with error or with `X-Trace-Force: 1` header (debugging).

### Required span attributes

| Attribute | Source | Notes |
|-----------|--------|-------|
| `mis.request.id` | `X-Request-ID` header | Cross-pillar key |
| `mis.user.id` | JWT claim | Omitted on public routes |
| `mis.tenant` | If multi-tenant | — |
| `service.name` | OTel resource | e.g. `case-service` |
| `service.version` | Image tag | For deploy correlation |

### Propagation across Kafka

Producers inject W3C `traceparent` into Kafka message headers; consumers extract and continue the span. This lets a single trace span from inbound REST → DB → Kafka publish → consumer service → email send.

## 5. Logs — ELK Stack

### Pipeline

```
stdout (JSON) ─▶ Filebeat (DaemonSet) ─▶ Logstash ─▶ Elasticsearch ─▶ Kibana
```

All services log structured JSON to stdout. Kubernetes captures stdout, Filebeat ships, Logstash parses + enriches, Elasticsearch indexes by day (`mis-logs-YYYY.MM.DD`).

### Required log fields

```json
{
  "timestamp":      "2026-05-14T08:11:22.341Z",
  "level":          "info",
  "service":        "case-service",
  "version":        "1.4.2",
  "pod":            "case-service-5d6c7b9-abcde",
  "correlation_id": "req-7a3f...",
  "trace_id":       "8b3c...",
  "span_id":        "1f02...",
  "user_id":        "u-1042",
  "route":          "/cases/:id",
  "msg":            "case updated",
  "duration_ms":    47
}
```

### Retention

| Index pattern | Hot | Warm | Cold | Delete |
|---------------|----:|----:|----:|------:|
| `mis-logs-*` | 7 d | 30 d | 60 d | 90 d |
| `mis-audit-*` | 30 d | 90 d | 180 d | 365 d |
| `mis-access-*` | 14 d | 30 d | 60 d | 90 d |

Audit index is separate, write-once, with stricter access control (only Admin Service + auditors).

### Sensitive data

A Logstash filter scrubs PII fields (national IDs, emails in payloads) at ingest. Authorization headers are never logged; JWT claims are extracted into structured fields but the raw token is dropped.

## 6. Correlation Across Pillars

A single failing request can be navigated from any pillar to the others using the `correlation_id`:

```
Grafana panel shows error spike
   │  click "View logs"
   ▼
Kibana filtered by correlation_id=req-7a3f...
   │  click "View trace"
   ▼
Jaeger trace timeline, full request graph across services
```

Grafana, Kibana, and Jaeger all expose deep-links keyed on `correlation_id`.

## 7. Alerting

Alertmanager routes by severity:

| Severity | Channel | Examples |
|----------|---------|----------|
| Critical | PagerDuty + Slack | Service down, error rate > 5 %, Kafka offline |
| Warning | Slack | p99 latency breach, Kafka lag > 10 k |
| Info | Slack (low-priority) | Deploy events, certificate rotation |

### Sample alert rules

```yaml
groups:
  - name: mis.critical
    rules:
      - alert: ServiceDown
        expr: up{job=~"mis-.*"} == 0
        for: 2m
        labels: { severity: critical }
        annotations:
          summary: "{{ $labels.job }} is down"

      - alert: HighErrorRate
        expr: mis:http_error_ratio_5m > 0.05
        for: 5m
        labels: { severity: critical }
        annotations:
          summary: "{{ $labels.service }} error rate above 5%"

      - alert: KafkaConsumerLag
        expr: kafka_consumer_lag > 10000
        for: 10m
        labels: { severity: warning }

      - alert: CircuitBreakerOpen
        expr: circuit_breaker_state == 2
        for: 5m
        labels: { severity: warning }
```

Runbooks for every critical alert live in `mis-config/runbooks/` and are linked from the alert annotation.

## 8. SLOs

| Service | SLI | Target | Error budget (30 d) |
|---------|-----|--------|---------------------|
| Auth | `ValidateToken` p99 latency | < 25 ms | 99.9 % under target |
| Kong | Availability | 99.95 % | 21 m 36 s |
| Case | API availability | 99.9 % | 43 m 12 s |
| Notification | Delivery within 5 min | 99 % | — |
| Sandbox | Verdict within 60 s | 95 % | — |

Burn-rate alerts (fast and slow windows) fire when error budget consumption rate exceeds thresholds, allowing earlier intervention than threshold-based alerts alone.
