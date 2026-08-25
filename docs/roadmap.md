# PulseStream Development Roadmap

This document outlines the implementation roadmap for the PulseStream platform.

Development is organized into structured engineering phases. Each phase corresponds to a set of GitHub issues tracked in the project board.

> **Authoritative status:** [`PROJECT_STATE.md`](../PROJECT_STATE.md) is the authoritative record of what is built. This roadmap describes the *plan* and each phase's outcome; where the two disagree, `PROJECT_STATE.md` is correct.
>
> Status words used here — **Planned**, **Implemented**, **Validated** — are defined in [`PROJECT_STATE.md`](../PROJECT_STATE.md#how-to-read-status-in-this-repository). Validation is environment-specific.

**Current phase: Phase 7.**

---

## Phase 1 — System Architecture

**Objective:** Define the architecture of the platform before implementation begins.

**Deliverables:**

*   System architecture documentation — implemented
*   Event schema definition — implemented
*   Service boundaries — implemented
*   Architecture diagrams — implemented
*   Architecture decision records (ADRs 0001–0005) — implemented

**Status:** Complete.

---

## Phase 2 — Local Development Platform

**Objective:** Create a reproducible local development environment.

**Deliverables:**

*   Docker Compose environment — implemented
*   Kafka cluster configuration — implemented
*   PostgreSQL setup with an initialisation script — implemented
*   Redis cache — provisioned; unused by application code
*   Observability stack for development (Prometheus, Grafana, Jaeger) — implemented

**Outcome:** Developers run the shared infrastructure locally with `docker compose up -d`. The Spring Boot services run from their service directories against that infrastructure.

**Status:** Complete.

---

## Phase 3 — Core Event Pipeline

**Objective:** Implement the core telemetry ingestion and processing pipeline.

**Deliverables:**

*   Ingestion service — implemented
*   Telemetry API endpoint — implemented as `POST /api/v1/events`
*   Kafka producer implementation — implemented for raw telemetry
*   Telemetry processor — implemented for raw event consumption, normalization, anomaly detection, and downstream publishing
*   Event persistence in PostgreSQL — implemented for normal processed telemetry
*   Anomaly persistence — **re-scoped to Phase 7** ([#267](https://github.com/ME-Massine/pulsestream/issues/267))
*   Query API — **re-scoped to Phase 7** ([#266](https://github.com/ME-Massine/pulsestream/issues/266)); `query-service` exists as a scaffold only

**Outcome:** Normal telemetry events flow from API to Kafka to processor to PostgreSQL. Anomalous events are published to Kafka. Anomaly persistence and query access are production read-side concerns and were moved into Phase 7 rather than left as open Phase 3 gaps.

**Status:** Complete, with the read-side deliverables re-scoped.

---

## Phase 4 — Observability

**Objective:** Introduce monitoring and tracing for the platform.

**Deliverables:**

*   Prometheus metrics endpoints — implemented in all three services
*   Prometheus local scrape configuration — implemented
*   Grafana datasource and dashboard provisioning — implemented for the local stack
*   Distributed tracing — **implemented and validated under Docker Compose.** `ingestion-service` and `telemetry-processor` carry the OpenTelemetry Spring Boot starter, propagate W3C `tracecontext` and `baggage`, export OTLP over `http/protobuf`, and correlate logs with `trace_id` / `span_id`. `query-service` is not instrumented.
*   Service health monitoring — implemented through actuator health endpoints and Kubernetes probe groups

**Outcome:** Operational visibility into the platform in the local development stack. The equivalent in-cluster stack is Phase 6 work and is still open.

**Status:** Complete under Docker Compose.

---

## Phase 5 — Reliability and Resilience

**Objective:** Improve platform fault tolerance.

**Deliverables:**

*   Dead-letter queue handling — implemented in both services; validated under Docker Compose
*   Event replay capability — implemented as a bounded, operator-selected replay from `telemetry.events.dlq` back to `telemetry.events.raw`; validated under Docker Compose
*   Retry mechanisms — implemented as producer-side retries with bounded delivery and publish timeouts
*   Failure isolation — implemented; Kafka buffering decouples ingestion from downstream processing failures, and the state-changing replay endpoint is isolated on a loopback-bound management port

**Outcome:** Failed events are captured rather than lost, and can be replayed deliberately. Replay *correctness* under reprocessing — reclassification and projection consistency — is Phase 7 work ([#271](https://github.com/ME-Massine/pulsestream/issues/271)).

**Status:** Complete. See [`architecture/event-replay-strategy.md`](architecture/event-replay-strategy.md).

---

## Phase 6 — Kubernetes Deployment

**Objective:** Deploy the platform to a Kubernetes environment.

**Deliverables:**

*   Kubernetes manifests — implemented for all three services, with probes, resource requests and limits, ConfigMaps, and out-of-band Secrets
*   Service deployments — validated on a live cluster
*   Kafka cluster deployment — implemented via the Strimzi operator in KRaft mode with persistent storage and declarative topics; validated
*   Service networking — ClusterIP services, documented DNS conventions, NodePort external ingestion, and default-deny NetworkPolicies; validated
*   Autoscaling — CPU-based HPAs for both stream-path services plus a custom-metrics path through the Prometheus adapter; **end-to-end behaviour under load is not yet validated** ([#153](https://github.com/ME-Massine/pulsestream/issues/153))
*   Observability stack in Kubernetes — **partial.** An OpenTelemetry Collector is deployed and receives spans, but traces terminate in its `debug` exporter. Prometheus ([#154](https://github.com/ME-Massine/pulsestream/issues/154)), Grafana ([#155](https://github.com/ME-Massine/pulsestream/issues/155)), dashboards ([#156](https://github.com/ME-Massine/pulsestream/issues/156)), a trace backend ([#158](https://github.com/ME-Massine/pulsestream/issues/158)), and end-to-end validation ([#159](https://github.com/ME-Massine/pulsestream/issues/159)) are outstanding.
*   PostgreSQL in the cluster — **not delivered.** Service ConfigMaps address `postgres:5432`; no manifest is committed.

**Outcome:** The platform deploys to a cluster and processes telemetry there. Its in-cluster observability is not yet at the level the local stack reaches.

**Status:** In progress. Tracked under [#26](https://github.com/ME-Massine/pulsestream/issues/26), whose remaining children are [#31](https://github.com/ME-Massine/pulsestream/issues/31) and [#32](https://github.com/ME-Massine/pulsestream/issues/32).

---

## Phase 7 — Production Readiness and Platform Hardening

**Objective:** Turn the deployable platform into a secure, operable, versioned, production-ready single-cluster release.

Phase 7 completes the platform's read side, strengthens distributed-processing guarantees, introduces enforceable engineering quality gates, secures the ingress and the Kafka client path, and validates the platform under realistic load and failure conditions.

**Deliverables** (each a sub-issue of [#254](https://github.com/ME-Massine/pulsestream/issues/254)):

*   **Engineering quality and release foundations** ([#255](https://github.com/ME-Massine/pulsestream/issues/255)) — documentation synchronization, complete CI quality gates, supply-chain security automation, and a versioned release and image promotion workflow.
*   **Production data contracts and query capabilities** ([#256](https://github.com/ME-Massine/pulsestream/issues/256)) — version-controlled schema migrations, a processed-telemetry query API, persisted and queryable anomalies, and versioned event contracts with compatibility validation.
*   **Distributed processing correctness** ([#257](https://github.com/ME-Massine/pulsestream/issues/257)) — deterministic anomaly detection under horizontal scaling, PostgreSQL and Kafka delivery consistency, and correct replay reclassification.
*   **Runtime observability, security, and operations** ([#258](https://github.com/ME-Massine/pulsestream/issues/258)) — custom processing and consumer-lag metrics, authenticated and encrypted external ingestion, secured Kafka communication and production secrets, and SLOs, alerts and runbooks.
*   **Release validation and publication** ([#259](https://github.com/ME-Massine/pulsestream/issues/259)) — load, failure-recovery and durability evidence, and the first versioned release with immutable images, an SBOM, and documented upgrade and rollback procedures.

**Outcome:** A clean environment can deploy a documented PulseStream release through one supported workflow; a client can submit telemetry and query the resulting normal or anomalous projection; ingestion and Kafka traffic are authenticated and encrypted; and recovery, load and durability results are published with the release.

**Out of scope:** multi-region or multi-cluster deployment, service mesh adoption, machine-learning anomaly detection, enterprise identity federation, multi-tenant billing and quotas, long-duration capacity tuning, and automated cloud infrastructure provisioning.

**Status:** In progress — current phase.

---

## Long-Term Improvements

Beyond Phase 7, future enhancements may include:

*   Advanced anomaly detection models
*   Stream processing with Kafka Streams or Flink
*   Time-series optimized storage
*   Multi-tenant telemetry isolation
*   Edge device authentication
*   A device simulator for synthetic telemetry load

---

## Related Documentation

```bash
PROJECT_STATE.md
docs/platform-overview.md
docs/architecture/
docs/diagrams/
docs/decisions/
```
