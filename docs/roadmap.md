# PulseStream Development Roadmap

This document outlines the implementation roadmap for the PulseStream platform.

Development is organized into structured engineering phases. Each phase corresponds to a set of GitHub issues tracked in the project board.

This roadmap describes **what each phase set out to deliver and whether it did**. For the detailed state of every capability — including which behaviour has been validated end-to-end and which gaps remain — [PROJECT_STATE.md](../PROJECT_STATE.md) is the authoritative source.

Status terms used below have the meanings defined in [PROJECT_STATE.md](../PROJECT_STATE.md#how-status-is-expressed): **implemented** (present and tested here), **validated** (additionally verified end-to-end by a script in `scripts/`), **planned** (absent, tracked by an issue).

---

## Phase 1 — System Architecture

**Objective:** Define the architecture of the platform before implementation begins.

**Deliverables:**

*   System architecture documentation — implemented
*   Event schema definition — implemented
*   Service boundaries — implemented
*   Architecture diagrams — implemented
*   Architecture decision records (ADRs) — implemented

**Status:** Complete.

**Outcome:** The platform had a documented target architecture, event contract and service split before any service was written.

---

## Phase 2 — Local Development Platform

**Objective:** Create a reproducible local development environment.

**Deliverables:**

*   Docker Compose environment — implemented
*   Kafka cluster configuration and topic provisioning — implemented
*   PostgreSQL setup with an init script — implemented
*   Redis cache — provisioned, and still unused by any service
*   Observability stack for development (Prometheus, Grafana, Jaeger) — implemented

**Status:** Complete.

**Outcome:** Developers run the shared infrastructure locally with `docker compose up -d`. Spring Boot services run from their service directories against that infrastructure.

---

## Phase 3 — Core Event Pipeline

**Objective:** Implement the core telemetry ingestion and processing pipeline.

**Deliverables:**

*   Ingestion service — implemented
*   Telemetry API endpoint — implemented as `POST /api/v1/events`
*   Kafka producer — implemented for raw telemetry
*   Telemetry processor — implemented for raw event consumption, normalization, anomaly detection and downstream publishing
*   Event persistence in PostgreSQL — implemented for normal processed telemetry, upserted by `event_id`
*   Anomaly persistence — re-scoped to Phase 7 (#267)
*   Query API — re-scoped to Phase 7 (#266)

**Status:** Complete. Two deliverables were re-scoped rather than dropped: anomaly persistence and the query API both require the schema-migration and data-contract work that Phase 7 owns, so they moved to #256 rather than being built on an init-script schema.

**Outcome:** Telemetry flows end to end from API to Kafka to processor to PostgreSQL. Anomalies are published to `telemetry.events.anomalies` but not persisted. `query-service` exists as a scaffold with actuator endpoints and no business functionality.

---

## Phase 4 — Observability

**Objective:** Introduce monitoring and tracing for the platform.

**Deliverables:**

*   Prometheus metrics endpoints — implemented in all three services
*   Prometheus scrape configuration — implemented and validated locally (`scripts/validate-prometheus-metrics.ps1`)
*   Grafana dashboards — implemented for service health and ingestion metrics, validated locally (`scripts/validate-grafana-datasource.ps1`)
*   Distributed tracing — implemented with OpenTelemetry and W3C context propagation, exported over OTLP to Jaeger, and validated across the HTTP hop (`scripts/validate-distributed-tracing.ps1`)
*   Service health monitoring — implemented through actuator health endpoints and Kubernetes probe groups

**Status:** Complete for the local platform.

**Outcome:** The platform is observable end to end locally. Two known gaps carry into Phase 7: `ingestion-service` emits no Kafka producer span, so traces stop at the HTTP boundary (#294), and no consumer-lag or custom processing metric is exported (#272). `telemetry-processor` is deliberately not a scrape target — its actuator surface, including the state-changing `dlqreplay` endpoint, is bound to loopback.

---

## Phase 5 — Reliability and Resilience

**Objective:** Improve platform fault tolerance.

**Deliverables:**

*   Dead-letter queue handling — implemented in both services and validated (`scripts/validate-dlq-pipeline.ps1`)
*   Event replay capability — implemented as operator-triggered, selective and bounded DLQ replay, and validated (`scripts/validate-event-replay.ps1`)
*   Retry mechanisms — implemented on the producer path (bounded retries with `acks=all`); the consumer path deliberately has **no** retry policy and dead-letters on first failure
*   Failure isolation — implemented: an ingestion publish failure preserves the event in the DLQ rather than failing the request path, and processing failures do not block the raw topic

**Status:** Complete.

**Outcome:** A failed event is preserved rather than lost, and an operator can replay a chosen set of dead-letter events into the pipeline without replaying the whole topic. The design and its trade-offs are documented in [event-replay-strategy.md](./architecture/event-replay-strategy.md). Replay reclassification consistency is Phase 7 work (#271).

---

## Phase 6 — Kubernetes Deployment

**Objective:** Deploy the platform to a Kubernetes environment.

**Deliverables:**

*   Kubernetes manifests for all services — implemented, with resource requests and limits, probes and externalized configuration
*   Container images — implemented against a shared build standard and published by CI
*   Kafka cluster deployment — implemented in KRaft mode via Strimzi, with persistent storage and provisioned topics, and validated (`scripts/validate-kafka-kubernetes.ps1`)
*   Service networking — implemented as ClusterIP services with documented DNS conventions plus a NodePort for external ingestion, with NetworkPolicies, and validated (`scripts/validate-service-connectivity.ps1`, `scripts/validate-network-policies.ps1`)
*   Horizontal autoscaling — implemented on CPU for both processing services and on a Prometheus custom metric for ingestion, and validated end-to-end (`scripts/validate-autoscaling-behavior.ps1`)
*   Observability stack in Kubernetes — partially implemented: the OpenTelemetry Collector, Prometheus and a base Grafana are deployed; the Grafana datasource and dashboards (#156), a tracing backend (#158) and end-to-end validation (#159) are open

**Status:** In progress. The three remaining issues all have open pull requests.

**Outcome:** The platform runs in a cluster and scales under load. One structural limitation remains outside the phase scope: no PostgreSQL manifests exist, so the processor's ConfigMap points at a `postgres` Service that must be supplied out of band.

---

## Phase 7 — Production Readiness and Platform Hardening

**Objective:** Turn a functionally complete platform into one that can be operated, secured and released.

Phase 7 is tracked by parent issue #254 and organised into five workstreams:

| Workstream | Issue | Deliverables |
| :--- | :--- | :--- |
| Engineering quality and release foundations | #255 | Complete CI quality gates, supply-chain security automation, a versioned release and image promotion workflow, and documentation that matches the platform |
| Production data contracts and query capabilities | #256 | Version-controlled schema migrations, the processed telemetry query API, anomaly persistence and querying, and versioned event contracts with compatibility validation |
| Distributed processing correctness and scalability | #257 | Deterministic anomaly detection under horizontal scaling, PostgreSQL and Kafka delivery consistency, and correct replay reclassification |
| Runtime observability, security, and operations | #258 | Custom processing and consumer-lag metrics, secured external ingestion, secured Kafka communication and secrets, and platform SLOs, alerts and runbooks |
| Release validation and publication | #259 | Load, failure-recovery and durability validation, and the first versioned PulseStream release |

**Outcome:** A platform whose data contracts are versioned and queryable, whose processing is correct under scale-out, which is secured and instrumented well enough to operate against defined SLOs, and which ships as a validated, versioned release.

---

## Long-Term Improvements

Beyond Phase 7, future enhancements may include:

*   Advanced anomaly detection models
*   Stream processing with Kafka Streams or Flink
*   Time-series optimized storage
*   Multi-tenant telemetry isolation
*   Edge device authentication
*   A device simulator for large-scale synthetic telemetry

---

## Related Documentation

```bash
PROJECT_STATE.md
docs/platform-overview.md
docs/architecture/
docs/diagrams/
docs/decisions/
```
