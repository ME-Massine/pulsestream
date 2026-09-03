# PulseStream — Project State

This document is the **authoritative source for the current engineering state and development progress of the PulseStream platform.** When `README.md`, `docs/roadmap.md`, and this file disagree, this file wins and the others should be reconciled to it.

PulseStream is a cloud-native event processing platform engineered for the ingestion, streaming, processing, and analysis of IoT telemetry events.

> **Reading the status labels.** This document distinguishes three levels of maturity:
>
> - **Implemented** — code and/or manifests are committed and covered by tests, but not yet validated end to end in a live target cluster.
> - **Validated** — behavior has been exercised and confirmed against a running environment, with evidence recorded in the repository.
> - **Planned** — designed and/or tracked by an issue, but not yet built.

---

### Progress Tracker

| Phase | Description | Status |
| :--- | :--- | :--- |
| **Phase 1** | Architecture and Design | ✅ Completed |
| **Phase 2** | Local Development Platform | ✅ Completed |
| **Phase 3** | Core Event Pipeline | ✅ Completed |
| **Phase 4** | Observability and Monitoring | ✅ Completed |
| **Phase 5** | Reliability and Resilience | ✅ Completed |
| **Phase 6** | Kubernetes Deployment | ✅ Completed |
| **Phase 7** | Production Readiness and Platform Hardening | 🚧 In Progress |

---

# Current Phase

### Phase 7 — Production Readiness and Platform Hardening (In Progress)

Phases 1 through 6 delivered a deployable, observable, resilient telemetry platform: HTTP ingestion, Kafka transport, stream processing with anomaly detection, PostgreSQL persistence, dead-letter and replay handling, distributed tracing, a Grafana/Prometheus observability stack, and Kubernetes manifests for every workload.

Phase 7 turns that deployable platform into a **secure, operable, versioned, production-ready single-cluster release.** It completes the read side (query APIs and anomaly persistence), strengthens distributed-processing correctness guarantees, introduces enforceable CI and supply-chain quality gates, secures ingestion and Kafka communication, and validates the platform under realistic load and failure conditions.

Phase 7 work is tracked under the **Phase 7 — Production Readiness and Platform Hardening** milestone and the Phase 7 parent issue (#254).

---

# Completed Work

### Repository Foundation
The repository structure and engineering workflows are established: GitHub project boards, standardized issue and pull request templates, contribution guidelines, and CI workflows under the MIT license.

### Architecture Design (Phase 1)
The core architecture of PulseStream is fully defined and documented, including the platform overview, service boundary definitions, event schema specifications, and a C4 architecture model. Detailed documentation is available in:
*   [Architecture Documentation](docs/architecture/)
*   [System Diagrams](docs/diagrams/)
*   [Platform Overview](docs/platform-overview.md)
*   [Development Roadmap](docs/roadmap.md)

### Architecture Decision Records (ADRs)
Key architectural choices are formalized through ADRs:
*   **ADR 0001**: Selection of Apache Kafka as the primary event streaming backbone.
*   **ADR 0002**: Adoption of Spring Boot for building platform microservices.
*   **ADR 0003**: Utilization of PostgreSQL as the primary persistence layer for the MVP.
*   **ADR 0004**: Implementation of Docker Compose for local development prior to Kubernetes orchestration.
*   **ADR 0005**: Selection of the Strimzi operator for deploying Kafka on Kubernetes.

Detailed records are maintained in the [Decisions](docs/decisions/) directory.

### Local Development Platform (Phase 2)
A reproducible local platform environment is available. Developers can instantiate the entire infrastructure stack — Kafka, Zookeeper, PostgreSQL, Redis, Prometheus, Grafana, and Jaeger — with a single command:
```bash
docker compose up -d
```
The configuration is managed via [infrastructure/docker/docker-compose.yml](infrastructure/docker/docker-compose.yml).

### Core Event Pipeline (Phase 3)
*   `ingestion-service` with `POST /api/v1/events` and request validation.
*   Kafka producer configuration for publishing raw telemetry to `telemetry.events.raw`.
*   `telemetry-processor` Kafka consumer for `telemetry.events.raw`.
*   Telemetry normalization and anomaly detection (threshold breach and sudden-deviation rules).
*   Processed event publishing to `telemetry.events.processed`.
*   Anomaly event publishing to `telemetry.events.anomalies`.
*   PostgreSQL persistence for normal processed telemetry in `platform.processed_telemetry`.

### Observability and Monitoring (Phase 4)
*   Spring Boot actuator health and Prometheus metrics endpoints in both runtime services.
*   Prometheus scrape configuration for the local stack.
*   Version-controlled Grafana dashboards (`observability/grafana/dashboards/`) provisioned automatically in the local stack and deployed in-cluster.
*   Distributed tracing via OpenTelemetry instrumentation, exporting OTLP traces to Jaeger locally and to an OpenTelemetry Collector in Kubernetes.

### Reliability and Resilience (Phase 5)
*   Dead-letter routing to `telemetry.events.dlq` (`DeadLetterPublisher`, `DeadLetterEventConsumer`).
*   Event replay from the dead-letter topic via a management endpoint (`DlqReplayService`, `DlqReplayEndpoint`, `ReplayEventPublisher`) with bounded, snapshot-based replay sessions.
*   Retry and failure-isolation behavior in the processing consumers.
*   Documented [event replay strategy](docs/architecture/event-replay-strategy.md).

### Kubernetes Deployment (Phase 6)
Kubernetes manifests are committed for the full platform under [infrastructure/kubernetes/](infrastructure/kubernetes/):
*   Deployments, Services, and ConfigMaps for `ingestion-service`, `telemetry-processor`, and the `query-service` scaffold.
*   Kafka on Kubernetes via the Strimzi operator (`KafkaNodePool`, `Kafka`, and `KafkaTopic` resources).
*   In-cluster observability: Grafana, and an OpenTelemetry Collector.
*   Horizontal Pod Autoscalers, including CPU-based and Prometheus-adapter custom-metrics autoscaling.
*   Network policies for service-to-service isolation.
*   Container build, image registry, and image validation standards.

---

# Current Work

### Phase 7 — Production Readiness and Platform Hardening
The objective of this phase is to deliver a secure, operable, versioned, production-ready release. Deliverables tracked under the Phase 7 milestone include:

*   **Engineering quality and release foundations** — complete CI quality gates for every component; automated dependency, secret, code, and container security checks; versioned release and container-image promotion workflow.
*   **Production data contracts and query capabilities** — version-controlled PostgreSQL schema migrations; a processed-telemetry query API; persisted and queryable anomaly projections; versioned event contracts with compatibility validation.
*   **Distributed processing correctness and scalability** — deterministic anomaly detection under horizontal scaling; PostgreSQL/Kafka delivery consistency; correct replay reclassification and projection consistency.
*   **Runtime observability, security, and operations** — secured external ingestion (TLS + authentication); secured Kafka client communication and production secret management; custom processing and consumer-lag metrics; SLOs, alerts, dashboards, and operational runbooks.
*   **Validation and release** — load, failure-recovery, and data-durability validation; publication of the first versioned PulseStream release.

**Target Outcome:**
```text
A clean environment can deploy a documented, versioned PulseStream release using one supported
workflow; a client can submit telemetry over an authenticated channel and query the resulting
normal or anomalous projection; and recovery, load, and durability tests pass with documented evidence.
```

---

# Remaining Platform Gaps

These are the primary capabilities that are **not yet implemented** at the start of Phase 7:

*   Application-level persistence of detected anomalies (anomalies are currently published to `telemetry.events.anomalies` only) — issue #267.
*   Query API business logic for processed telemetry and anomalies (the `query-service` is a scaffold only) — issues #266, #267.
*   Version-controlled PostgreSQL schema migrations — issue #265.
*   Authenticated and encrypted external ingestion — issue #273.
*   Secured Kafka client communication and production secret management — issue #275.
*   Versioned event contracts with compatibility validation — issue #268.
*   Device simulator tooling.
*   Missing-heartbeat anomaly detection.
*   End-to-end validation of the committed Kubernetes manifests against a live target cluster.

---

# Repository Structure

```text
docs/
├─ architecture/
├─ diagrams/
├─ decisions/
├─ platform-overview.md
└─ roadmap.md

infrastructure/
├─ docker/
└─ kubernetes/

observability/
└─ grafana/dashboards/

services/
├─ ingestion-service/
├─ telemetry-processor/
└─ query-service/
```

---

# Long-Term Vision

PulseStream is designed to serve as a reference implementation for modern distributed systems. The project demonstrates best practices in event-driven microservices, scalable streaming pipelines, cloud-native deployment patterns, and production-grade observability. It provides a practical framework for building resilient and scalable event-processing systems.
