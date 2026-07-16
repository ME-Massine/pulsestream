# PulseStream — Project State

This document serves as the official record for tracking the current engineering state and development progress of the PulseStream platform. PulseStream is a cloud-native event processing platform engineered for the ingestion, streaming, processing, and analysis of IoT telemetry events.

### Progress Tracker

| Phase | Description | Status |
| :--- | :--- | :--- |
| **Phase 1** | Architecture and Design | ✅ Completed |
| **Phase 2** | Local Development Platform | ✅ Completed |
| **Phase 3** | Core Event Pipeline | 🚧 In Progress |
| **Phase 4** | Observability and Monitoring | 🚧 Foundations Started |
| **Phase 5** | Reliability and Resilience | ⏳ Planned |
| **Phase 6** | Kubernetes Deployment | 🚧 Manifests implemented, pending live-cluster verification |

---

# Current Phase

### Phase 3 — Core Event Pipeline (In Progress)

The project has implemented the first functional telemetry path from HTTP ingestion through Kafka processing to PostgreSQL persistence for normal processed telemetry events. The current focus is on closing remaining pipeline gaps, especially documented failure handling, DLQ workflows, anomaly persistence, and query APIs.

---

# Completed Work

### Repository Foundation
The initial repository structure and engineering workflows have been established to support collaborative development. This includes the implementation of GitHub project boards, standardized issue and pull request templates, comprehensive contribution guidelines, and a baseline CI workflow under the MIT license.

### Architecture Design
The core architecture of PulseStream has been fully defined and documented. This foundational work includes the platform overview, service boundary definitions, event schema specifications, and a comprehensive C4 architecture model. Detailed documentation is available in the following locations:
*   [Architecture Documentation](docs/architecture/)
*   [System Diagrams](docs/diagrams/)
*   [Platform Overview](docs/platform-overview.md)
*   [Development Roadmap](docs/roadmap.md)

### Architecture Decision Records (ADRs)
Key architectural choices have been formalized through ADRs to ensure transparency and long-term maintainability:
*   **ADR 0001**: Selection of Apache Kafka as the primary event streaming backbone.
*   **ADR 0002**: Adoption of Spring Boot for building platform microservices.
*   **ADR 0003**: Utilization of PostgreSQL as the primary persistence layer for the MVP.
*   **ADR 0004**: Implementation of Docker Compose for local development prior to Kubernetes orchestration.

Detailed records are maintained in the [Decisions](docs/decisions/) directory.

### Local Development Platform (Phase 2)
The goal of creating a reproducible local platform environment has been achieved. Developers can now instantiate the entire infrastructure stack, including Kafka, Zookeeper, PostgreSQL, Redis, Prometheus, and Grafana, using a single command:
```bash
docker compose up -d
```
The configuration is managed via the [infrastructure/docker/docker-compose.yml](infrastructure/docker/docker-compose.yml) file.

### Kubernetes Deployment (Phase 6, manifests)
The platform's Kubernetes manifests, kept as the cluster counterpart to the local Docker Compose stack (same images, env var contracts, Kafka topics, Postgres schema, and Grafana dashboards), can be applied with:
```bash
kubectl apply -k infrastructure/kubernetes
```
See [infrastructure/kubernetes/README.md](infrastructure/kubernetes/README.md) for prerequisites, image build/load steps, and what's deployed.

### Core Event Pipeline Implemented So Far
The current checkout includes:
*   `ingestion-service` with `POST /api/v1/events` and request validation.
*   Kafka producer configuration for publishing raw telemetry to `telemetry.events.raw`.
*   `telemetry-processor` Kafka consumer configuration for `telemetry.events.raw`.
*   Telemetry normalization and basic anomaly detection.
*   Processed event publishing to `telemetry.events.processed`.
*   Anomaly event publishing to `telemetry.events.anomalies`.
*   PostgreSQL persistence for normal processed telemetry in `platform.processed_telemetry`.
*   Spring Boot actuator Prometheus endpoints in both services.

---

# Current Work

### Phase 3 — Core Event Pipeline
The objective of this phase is to complete the first functional end-to-end telemetry pipeline. Several critical components are already implemented:
*   **Ingestion-service foundation**: Implemented.
*   **Telemetry ingestion API**: Implemented as `POST /api/v1/events`.
*   **Kafka producer integration**: Implemented for raw telemetry publishing.
*   **Telemetry-processor service**: Implemented for Kafka consumption, normalization, anomaly detection, and downstream publishing.
*   **PostgreSQL persistence**: Implemented for normal processed telemetry records.

Remaining Phase 3 gaps include:
*   Persisting anomaly records from application code.
*   Defining and implementing DLQ routing behavior.
*   Adding query APIs or a query service for persisted telemetry.
*   Confirming schema initialization behavior for local PostgreSQL environments.

**Target Outcome:**
```text
API → Kafka → Processor → PostgreSQL
```

---

# Upcoming Phases

### Phase 4 — Observability
This phase will expand the current observability foundation. The services already expose Spring Boot actuator health and Prometheus endpoints, and the local Docker platform includes Prometheus and Grafana. Remaining deliverables include complete scrape coverage, dashboard configuration, distributed tracing via OpenTelemetry, and automated service health monitoring.

### Phase 5 — Reliability and Resilience
The focus will shift toward enhancing the platform's fault tolerance. This includes the implementation of dead-letter queues (DLQs), event replay capabilities, robust retry mechanisms, and failure isolation patterns to ensure system stability under stress.

### Phase 6 — Kubernetes Deployment
The platform can now be deployed to Kubernetes with a single `kubectl apply -k infrastructure/kubernetes`. Manifests are implemented for both services (`ingestion-service`, `telemetry-processor`), Kafka/Zookeeper, PostgreSQL, Redis, and the observability stack (Prometheus, Grafana, Jaeger), including HPAs for both application services and NodePort/Ingress exposure for the ingestion API. Details in [infrastructure/kubernetes/README.md](infrastructure/kubernetes/README.md).

Deliberately deferred: the issue's original scope named `analytics-consumer` and `query-service`, which do not exist yet in this repo (only `ingestion-service` and `telemetry-processor` are implemented) — Kubernetes manifests for those services will follow once they're built. Kafka-consumer-lag-based autoscaling is provided as an optional KEDA `ScaledObject` rather than a default HPA, since vanilla Kubernetes HPA cannot read consumer group lag on its own. This phase has not yet been verified against a live cluster.

---

# Next Immediate Task

The current priority is to close the remaining Phase 3 pipeline gaps and keep documentation synchronized with implementation.

**Current Focus Areas:**
*   Anomaly persistence and schema alignment.
*   DLQ behavior and failure routing.
*   Query API or query service design.
*   Local PostgreSQL schema initialization flow.
*   Observability scrape coverage and dashboard setup.

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
```

---

# Long-Term Vision

PulseStream is designed to serve as a reference implementation for modern distributed systems. The project aims to demonstrate best practices in event-driven microservices, scalable streaming pipelines, cloud-native deployment patterns, and production-grade observability. It provides a practical framework for building resilient and scalable event-processing systems.
