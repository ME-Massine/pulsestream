# PulseStream Development Roadmap

This document outlines the implementation roadmap for the PulseStream platform.

Development is organized into structured engineering phases. Each phase corresponds to a set of GitHub issues tracked in the project board.

The authoritative, up-to-date status of the platform is tracked in [PROJECT_STATE.md](../PROJECT_STATE.md). This roadmap describes the intended scope and outcome of each phase; where the two disagree, `PROJECT_STATE.md` is authoritative.

**Current phase:** Phase 7 — Production Readiness and Platform Hardening. Phases 1 through 6 are complete.

---

## Phase 1 — System Architecture

**Objective:** Define the architecture of the platform before implementation begins.

**Deliverables:**

*   System architecture documentation
*   Event schema definition
*   Service boundaries
*   Architecture diagrams
*   Architecture decision records (ADRs)

**Status:** Complete

---

## Phase 2 — Local Development Platform

**Objective:** Create a reproducible local development environment.

**Deliverables:**

*   Docker Compose environment
*   Kafka cluster configuration
*   PostgreSQL setup
*   Redis cache
*   Observability stack for development

**Outcome:** Developers can run the shared infrastructure locally. Spring Boot services run from their service directories against that local infrastructure.

---

## Phase 3 — Core Event Pipeline

**Objective:** Implement the core telemetry ingestion and processing pipeline.

**Deliverables:**

*   Ingestion service — implemented
*   Telemetry API endpoint — implemented as `POST /api/v1/events`
*   Kafka producer implementation — implemented for raw telemetry
*   Telemetry processor — implemented for raw event consumption, normalization, anomaly detection, and downstream publishing
*   Event persistence in PostgreSQL — implemented for normal processed telemetry
*   Anomaly persistence — planned (Phase 7, #267)
*   Query API — planned (Phase 7, #266)

**Status:** Complete

**Outcome:** Normal telemetry events flow from API to Kafka to processor to PostgreSQL. Anomalous events are published to `telemetry.events.anomalies`. Application-level anomaly persistence and query APIs are deferred to Phase 7.

---

## Phase 4 — Observability

**Objective:** Introduce monitoring and tracing for the platform.

**Deliverables:**

*   Prometheus metrics endpoints — implemented in services
*   Prometheus scrape configuration — implemented for the local stack
*   Grafana dashboards — implemented (version-controlled JSON, provisioned locally and in-cluster)
*   Distributed tracing — implemented via OpenTelemetry (OTLP export to Jaeger locally, OpenTelemetry Collector in Kubernetes)
*   Service health monitoring — implemented through actuator health endpoints

**Status:** Complete

**Outcome:** Operational visibility into the platform through metrics, dashboards, health probes, and distributed traces.

---

## Phase 5 — Reliability and Resilience

**Objective:** Improve platform fault tolerance.

**Deliverables:**

*   Dead-letter queue handling — implemented (`telemetry.events.dlq` routing)
*   Event replay capability — implemented (bounded replay from the dead-letter topic via a management endpoint)
*   Retry mechanisms — implemented in the processing consumers
*   Failure isolation — implemented

**Status:** Complete

**Outcome:** Robust event processing during service failures, with dead-letter capture and operator-driven replay. See the [event replay strategy](architecture/event-replay-strategy.md).

---

## Phase 6 — Kubernetes Deployment

**Objective:** Deploy the platform to a Kubernetes environment.

**Deliverables:**

*   Kubernetes manifests — implemented for all workloads under `infrastructure/kubernetes/`
*   Service deployments — implemented for `ingestion-service`, `telemetry-processor`, and the `query-service` scaffold
*   Kafka cluster deployment — implemented via the Strimzi operator
*   Observability stack in Kubernetes — implemented (Grafana, OpenTelemetry Collector)
*   Autoscaling — implemented (CPU-based and custom-metrics HPAs)
*   Network isolation — implemented (network policies)

**Status:** Complete

**Outcome:** Committed, reviewable manifests deploy the full platform to a Kubernetes cluster. End-to-end validation against a live target cluster is completed as part of Phase 7.

---

## Phase 7 — Production Readiness and Platform Hardening

**Objective:** Turn the deployable platform into a secure, operable, versioned, production-ready single-cluster release.

**Deliverables:**

*   Complete CI quality gates and automated dependency, secret, code, and container security checks
*   Version-controlled PostgreSQL schema migrations
*   Processed-telemetry query API and persisted, queryable anomaly projections
*   Versioned event contracts with compatibility validation
*   Deterministic anomaly detection under horizontal scaling
*   Reliable PostgreSQL and Kafka delivery consistency, and correct replay reclassification
*   Authenticated, encrypted external ingestion and secured Kafka client communication
*   Custom processing and consumer-lag metrics; SLOs, alerts, dashboards, and operational runbooks
*   Load, failure-recovery, and data-durability validation
*   Automated versioned releases and container-image promotion

**Status:** In Progress

**Outcome:** A clean environment can deploy a documented, versioned PulseStream release using one supported workflow; a client can submit telemetry over an authenticated channel and query the resulting normal or anomalous projection; and recovery, load, and durability tests pass with documented evidence. Tracked under the Phase 7 milestone and parent issue #254.

---

## Long-Term Improvements

Future enhancements may include:

*   Advanced anomaly detection models
*   Stream processing with Kafka Streams or Flink
*   Time-series optimized storage
*   Multi-tenant telemetry isolation
*   Edge device authentication

---

## Related Documentation

Architecture documentation:

```bash
docs/platform-overview.md
docs/architecture/
docs/diagrams/
docs/decisions/
```
