# PulseStream Development Roadmap

This document outlines the implementation roadmap for the PulseStream platform.

Development is organized into structured engineering phases. Each phase corresponds to a set of GitHub issues tracked in the project board.

Phase status here is a summary. [`PROJECT_STATE.md`](../PROJECT_STATE.md) is the authoritative record of what exists, and defines the **implemented / validated / planned** vocabulary used below.

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

---

## Phase 2 — Local Development Platform

**Objective:** Create a reproducible local development environment.

**Deliverables:**

*   Docker Compose environment — implemented
*   Kafka cluster configuration — implemented
*   PostgreSQL setup with schema init script — implemented
*   Redis cache — provisioned, not consumed by any service
*   Observability stack for development (Prometheus, Grafana, Jaeger) — implemented

**Outcome:** Developers run the shared infrastructure locally with `docker compose up -d`. Spring Boot services run from their service directories against that infrastructure.

**Status:** Complete.

---

## Phase 3 — Core Event Pipeline

**Objective:** Implement the core telemetry ingestion and processing pipeline.

**Deliverables:**

*   Ingestion service — implemented
*   Telemetry API endpoint — implemented as `POST /api/v1/events`
*   Kafka producer — implemented for raw telemetry
*   Telemetry processor — implemented for raw event consumption, normalization, anomaly detection, and downstream publishing
*   Event persistence in PostgreSQL — implemented for normal processed telemetry, idempotent by `event_id`
*   Anomaly persistence — planned, moved to Phase 7 ([#267](https://github.com/ME-Massine/pulsestream/issues/267))
*   Query API — planned, moved to Phase 7 ([#266](https://github.com/ME-Massine/pulsestream/issues/266))

**Outcome:** Telemetry flows from the API through Kafka to the processor to PostgreSQL. Anomalous events are published to Kafka. The read side of the platform was deliberately deferred to Phase 7 rather than delivered here.

**Status:** Complete for the write path.

---

## Phase 4 — Observability

**Objective:** Introduce monitoring and tracing for the platform.

**Deliverables:**

*   Prometheus metrics endpoints — implemented in both event-path services
*   Prometheus local scrape configuration — implemented
*   Grafana datasource and dashboards — implemented and provisioned from version-controlled JSON in `observability/grafana/dashboards/`
*   Distributed tracing — implemented via the OpenTelemetry Spring Boot starter in `ingestion-service` and `telemetry-processor`, exporting OTLP over `http/protobuf`
*   Service health monitoring — implemented through actuator health endpoints and Kubernetes probes

**Validated:** `scripts/validate-prometheus-metrics.ps1`, `scripts/validate-grafana-datasource.ps1`, `scripts/validate-distributed-tracing.ps1` — all against the local Docker Compose stack.

**Outcome:** Operational visibility into the platform locally. Custom processing and consumer-lag metrics are planned ([#272](https://github.com/ME-Massine/pulsestream/issues/272)); the missing Kafka producer span is tracked as a bug ([#294](https://github.com/ME-Massine/pulsestream/issues/294)).

**Status:** Complete for the local stack. In-cluster collection is Phase 6 work ([#32](https://github.com/ME-Massine/pulsestream/issues/32)).

---

## Phase 5 — Reliability and Resilience

**Objective:** Improve platform fault tolerance.

**Deliverables:**

*   Dead-letter queue handling — implemented in both `ingestion-service` and `telemetry-processor`, with error metadata on every record
*   Event replay capability — implemented as operator-triggered, selective DLQ replay through a loopback-bound actuator endpoint
*   Replay safeguards — implemented: replay markers and upsert-by-`event_id` persistence
*   Retry mechanisms — deliberately absent on the processor listener; failures go to the DLQ on first failure and are recovered by replay
*   Failure isolation — implemented: ingestion continues when downstream processing fails, because Kafka buffers and failures divert to the DLQ

**Validated:** `scripts/validate-dlq-pipeline.ps1` and `scripts/validate-event-replay.ps1`, end to end.

**Outcome:** Failed events are preserved rather than lost, and are recoverable on operator command. Strategy is documented in [event-replay-strategy.md](architecture/event-replay-strategy.md). Replay reclassification and projection consistency are refined in Phase 7 ([#271](https://github.com/ME-Massine/pulsestream/issues/271)).

**Status:** Complete.

---

## Phase 6 — Kubernetes Deployment

**Objective:** Deploy the platform to a Kubernetes environment.

**Deliverables:**

*   Container images — implemented under a shared build standard and published to a registry by CI
*   Kubernetes manifests and service deployments — implemented for all three services, with probes, ConfigMaps, and Secrets
*   Kafka cluster deployment — implemented via the Strimzi operator in KRaft mode with persistent storage and declarative topics
*   Service networking — implemented: ClusterIP services, a NodePort for external ingestion, documented DNS conventions, and NetworkPolicies
*   Horizontal pod autoscaling — implemented: CPU-based HPAs for both event-path services, plus a custom-metrics HPA definition for `ingestion-service`
*   OpenTelemetry Collector — implemented in the `observability` namespace
*   Observability stack in Kubernetes — planned ([#32](https://github.com/ME-Massine/pulsestream/issues/32))

**Validated:** Kafka broker health, service-to-service connectivity, external ingestion access, NetworkPolicy enforcement, and autoscaling behaviour end to end — see [autoscaling-validation.md](architecture/autoscaling-validation.md).

**Outcome:** The platform deploys and runs on Kubernetes. Two gaps remain: in-cluster Prometheus, Grafana, and a tracing backend ([#154](https://github.com/ME-Massine/pulsestream/issues/154), [#155](https://github.com/ME-Massine/pulsestream/issues/155), [#156](https://github.com/ME-Massine/pulsestream/issues/156), [#158](https://github.com/ME-Massine/pulsestream/issues/158), [#159](https://github.com/ME-Massine/pulsestream/issues/159)) — so cluster traces currently terminate in the collector's `debug` exporter — and PostgreSQL, which is configured for but not provisioned by any manifest.

**Status:** Complete except the in-cluster observability stack.

---

## Phase 7 — Production Readiness and Platform Hardening

**Objective:** Turn the deployable platform into a secure, operable, versioned, production-ready single-cluster release. Tracked under [#254](https://github.com/ME-Massine/pulsestream/issues/254).

**Deliverables:**

*   Complete CI quality gates for every service and infrastructure component ([#262](https://github.com/ME-Massine/pulsestream/issues/262))
*   Automated dependency, secret, code, and container security checks ([#263](https://github.com/ME-Massine/pulsestream/issues/263))
*   Versioned release and container image promotion workflow ([#264](https://github.com/ME-Massine/pulsestream/issues/264))
*   Version-controlled PostgreSQL schema migrations ([#265](https://github.com/ME-Massine/pulsestream/issues/265))
*   Processed telemetry query API ([#266](https://github.com/ME-Massine/pulsestream/issues/266))
*   Persistent and queryable anomaly projections ([#267](https://github.com/ME-Massine/pulsestream/issues/267))
*   Versioned event contracts with compatibility validation ([#268](https://github.com/ME-Massine/pulsestream/issues/268))
*   Deterministic anomaly detection under horizontal scaling ([#269](https://github.com/ME-Massine/pulsestream/issues/269))
*   PostgreSQL and Kafka delivery consistency ([#270](https://github.com/ME-Massine/pulsestream/issues/270))
*   Correct replay reclassification and projection consistency ([#271](https://github.com/ME-Massine/pulsestream/issues/271))
*   Custom processing and consumer-lag metrics ([#272](https://github.com/ME-Massine/pulsestream/issues/272))
*   Authenticated and encrypted external ingestion ([#273](https://github.com/ME-Massine/pulsestream/issues/273))
*   Secured Kafka communication and production secret management ([#275](https://github.com/ME-Massine/pulsestream/issues/275))
*   SLOs, alerts, dashboards, and operational runbooks ([#276](https://github.com/ME-Massine/pulsestream/issues/276))
*   Load, failure-recovery, and data-durability validation ([#277](https://github.com/ME-Massine/pulsestream/issues/277))
*   The first versioned PulseStream release ([#278](https://github.com/ME-Massine/pulsestream/issues/278))

**Outcome:** A clean environment can deploy a documented release through one supported workflow; a client can submit telemetry and query the resulting normal or anomalous projection; and recovery, load, and durability behaviour is backed by recorded evidence.

**Out of scope for this phase:** multi-region or multi-cluster deployment, service mesh, ML-based anomaly detection, enterprise SSO, multi-tenant billing and quotas, long-duration capacity tuning, and automated cloud infrastructure provisioning.

**Status:** In progress.

---

## Long-Term Improvements

Beyond Phase 7, future enhancements may include:

*   Advanced anomaly detection models
*   Stream processing with Kafka Streams or Flink
*   Time-series optimized storage
*   Multi-tenant telemetry isolation
*   Edge device authentication
*   A device simulator for synthetic load

---

## Related Documentation

```bash
PROJECT_STATE.md          # authoritative current status
docs/platform-overview.md
docs/architecture/
docs/diagrams/
docs/decisions/
```
