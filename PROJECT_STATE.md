# PulseStream — Project State

This document is the **authoritative record of the current engineering state** of the PulseStream platform. When `README.md`, `docs/roadmap.md`, an architecture document, or a GitHub issue disagrees with this file about what is built, this file is correct and the other document is stale.

PulseStream is a cloud-native event processing platform for the ingestion, streaming, processing, and analysis of IoT telemetry events.

---

## How status is expressed

Every status claim in the repository uses one of three terms. They are not interchangeable.

| Term | Meaning |
| :--- | :--- |
| **Implemented** | The code or manifests exist in this repository and are exercised by unit or integration tests. |
| **Validated** | Implemented, and additionally verified end-to-end against a running environment by a repeatable script in [scripts/](scripts/). The validating script is named wherever this term is used. |
| **Planned** | Not present in this repository. Tracked by a GitHub issue, which is referenced. |

"Implemented" never implies "validated". A capability can be implemented and unit-tested while its end-to-end behaviour in a running environment is still unproven.

---

## Progress Tracker

| Phase | Description | Status |
| :--- | :--- | :--- |
| **Phase 1** | Architecture and Design | Complete |
| **Phase 2** | Local Development Platform | Complete |
| **Phase 3** | Core Event Pipeline | Complete — anomaly persistence and the query API were re-scoped to Phase 7 (#266, #267) |
| **Phase 4** | Observability and Monitoring | Complete for the local platform — metrics and tracing implemented and validated |
| **Phase 5** | Reliability and Resilience | Complete — DLQ routing and bounded DLQ replay implemented and validated |
| **Phase 6** | Kubernetes Deployment | In progress — services, Kafka, networking, autoscaling and metrics collection deployed; in-cluster dashboards, tracing backend and end-to-end validation still open (#156, #158, #159) |
| **Phase 7** | Production Readiness and Platform Hardening | In progress — current phase (#254) |

---

# Current Phase

### Phase 7 — Production Readiness and Platform Hardening (#254)

Phase 7 turns a functionally complete platform into one that can be operated. It is organised into five workstreams, each a parent issue with its own sub-issues:

| Workstream | Parent issue | Scope |
| :--- | :--- | :--- |
| Engineering quality and release foundations | #255 | CI quality gates, supply-chain security, release and image promotion, documentation accuracy |
| Production data contracts and query capabilities | #256 | Schema migrations, query API, anomaly persistence and querying, versioned event contracts |
| Distributed processing correctness and scalability | #257 | Deterministic anomaly detection under scale-out, PostgreSQL/Kafka delivery consistency, replay reclassification |
| Runtime observability, security, and operations | #258 | Processing and consumer-lag metrics, ingestion and Kafka security, SLOs, alerts and runbooks |
| Release validation and publication | #259 | Load, failure-recovery and durability validation; the first versioned release |

Phase 6 finishes in parallel: its three remaining issues (#156, #158, #159) each have an open pull request and none of them blocks Phase 7 work.

---

# Implemented Platform Capabilities

### Ingestion — `services/ingestion-service`

* `POST /api/v1/events`, with bean-validated request and payload DTOs and a global exception handler returning structured error responses.
* Kafka producer publishing telemetry to `telemetry.events.raw` with `acks=all`, bounded retries and a bounded publish timeout.
* **Dead-letter routing.** When publishing an already-accepted event fails, the event is preserved as a `DeadLetterEvent` on `telemetry.events.dlq` with error metadata and a `sourceService` of `ingestion-service`, so an accepted event is not silently lost.
* Actuator `health`, `info` and `prometheus` on port 8081, with the Kubernetes liveness and readiness probe groups mirrored to `/livez` and `/readyz` on the service port.
* OpenTelemetry HTTP server spans and W3C `tracecontext`/`baggage` propagation, exported over OTLP `http/protobuf`. Trace and span IDs appear in the log pattern.

### Processing — `services/telemetry-processor`

* Kafka consumer on `telemetry.events.raw`, telemetry normalization, and threshold-based anomaly detection.
* The two outcomes are exclusive: a **normal** reading is published to `telemetry.events.processed` and persisted to `platform.processed_telemetry` in PostgreSQL, upserted by `event_id`; an **anomalous** reading is published to `telemetry.events.anomalies` only, and is neither persisted nor republished as processed telemetry.
* **Dead-letter routing.** A processing failure routes the event to `telemetry.events.dlq` on first failure. No retry policy is configured on the listener container, so a processor-sourced dead-letter record means "failed once", not "retries exhausted".
* **DLQ replay.** A `dlq-replay-listener` registered with `autoStartup=false`, driven by the `dlqreplay` actuator endpoint. Replay is *selective* — only operator-supplied `eventId` values are republished to `telemetry.events.raw` — and *bounded*: per-partition end offsets are snapshotted at trigger time, with an idle timeout as a fallback stop. Replayed events carry replay markers so downstream persistence stays idempotent.
* The actuator surface is served on a separate management port (`9083`) bound to loopback by default, because `dlqreplay` is state-changing and no authentication fronts the service yet. This is also why the processor is not a Prometheus scrape target in either environment.

### Query — `services/query-service`

* **Scaffold only.** A Spring Boot application exposing actuator `health`, `info` and `prometheus` on port 8083, with a production Dockerfile and Kubernetes Deployment, Service and ConfigMap manifests.
* It exposes **no REST endpoints and performs no database access**. The query API is #266; anomaly querying is #267.

### Event transport

* Four topics — `telemetry.events.raw`, `.processed`, `.anomalies` and `.dlq` — provisioned in both environments: a single broker at replication factor 1 in Compose (`infrastructure/docker/kafka/init-topics.sh`), and three brokers at replication factor 3 with `min.insync.replicas=2` as Strimzi `KafkaTopic` resources in Kubernetes.

### Local development platform

* Docker Compose stack — Kafka and Zookeeper, PostgreSQL 16, Redis 7, Prometheus, Grafana and Jaeger — started with `docker compose up -d`. Spring Boot services run from their service directories against it.
* Prometheus scrapes `ingestion-service`. Grafana dashboards for service health and ingestion metrics live in [observability/grafana/dashboards/](observability/grafana/dashboards/).
* Redis is provisioned but not used by any service. See [cache-strategy.md](docs/architecture/cache-strategy.md).

### Kubernetes deployment

* Deployment, Service and ConfigMap manifests for all three services, with resource requests and limits, probes and externalized configuration, plus a Secret example for processor database credentials.
* Kafka in KRaft mode through the Strimzi operator, with persistent storage and provisioned topics.
* Internal ClusterIP services with documented DNS conventions, a NodePort for external ingestion access, and NetworkPolicies isolating each service.
* CPU-based HorizontalPodAutoscalers for `ingestion-service` and `telemetry-processor`, plus a custom-metrics HPA for `ingestion-service` driven by `prometheus-adapter`.
* An OpenTelemetry Collector in the `observability` namespace; Prometheus (installed from a chart with version-controlled values) and a base Grafana deployment in the `monitoring` namespace.

### Container images and CI

* A shared multi-stage build standard across services, images published to the container registry by a GitHub Actions workflow, and local image validation.

---

# Validated Behaviour

The following were verified end-to-end against a running environment by scripts kept in this repository, not only by unit tests.

| Behaviour | Script |
| :--- | :--- |
| DLQ pipeline, both producers | `scripts/validate-dlq-pipeline.ps1`, `scripts/validate-kafka-dlq-topic.ps1` |
| Bounded, selective event replay | `scripts/validate-event-replay.ps1` |
| Distributed tracing across the HTTP hop | `scripts/validate-distributed-tracing.ps1` |
| Prometheus scraping and the Grafana datasource, locally and in cluster | `scripts/validate-prometheus-metrics.ps1`, `scripts/validate-prometheus-kubernetes.ps1`, `scripts/validate-grafana-datasource.ps1`, `scripts/validate-grafana-deployment.ps1` |
| Kafka broker health and connectivity in cluster | `scripts/validate-kafka-broker-health.ps1`, `scripts/validate-kafka-kubernetes.ps1` |
| Service-to-service connectivity, NetworkPolicies, external ingestion access | `scripts/validate-service-connectivity.ps1`, `scripts/validate-network-policies.ps1`, `scripts/validate-ingestion-external-access.ps1` |
| CPU and custom-metric autoscaling, including scale-up and scale-down behaviour | `scripts/validate-ingestion-hpa.ps1`, `scripts/validate-telemetry-processor-hpa.ps1`, `scripts/validate-custom-metrics-autoscaling.ps1`, `scripts/validate-autoscaling-behavior.ps1` |
| Container images build and run as specified | `scripts/validate-container-images.ps1` |

---

# Known Gaps and Limitations

These are the platform's real limitations at the start of Phase 7. Each one is tracked.

**Data and contracts**

* Detected anomalies are published to Kafka only. `platform.anomalies` exists in `infrastructure/docker/postgres/init.sql`, but no application code writes to it (#267).
* There is no query API. `query-service` is a scaffold (#266).
* The database schema is applied by an init script with `ddl-auto: none`; there is no versioned migration tool (#265).
* Event payloads have no versioned schema and no compatibility checking (#268).

**Correctness under scale**

* Anomaly detection state is per-instance, so results are not deterministic once the processor scales beyond one replica (#269).
* Kafka publication and PostgreSQL persistence are not committed together; a failure between them can leave the two stores disagreeing (#270).
* Replayed events are re-classified independently of their original outcome, so a replay can change an event's classification (#271).

**Observability**

* `ingestion-service` emits no Kafka producer span: its hand-built `ProducerFactory` beans are not instrumented, so a trace stops at the HTTP boundary (#294).
* No custom processing metrics and no consumer-lag metric are exported, which is why `telemetry-processor` still autoscales on CPU rather than on backlog (#272).
* In-cluster Grafana has no provisioned datasource or dashboards (#156), there is no tracing backend in the cluster (#158), and the in-cluster observability stack has not been validated end-to-end (#159).

**Security**

* The ingestion API is unauthenticated (#273).
* Kafka traffic is unencrypted and production secrets are unmanaged (#275).
* The loopback-bound management port is a mitigation, not a solution: `dlqreplay` itself has no authentication.

**Operations**

* No PostgreSQL manifests exist. The Kubernetes ConfigMap points `telemetry-processor` at a `postgres` Service that this repository does not provision, so a database must be supplied out of band.
* No SLOs, alerting rules or runbooks (#276).
* No load, failure-recovery or durability validation (#277), and no versioned release (#278).
* There is no device simulator. Synthetic load is generated by the validation scripts.

---

# Architecture Decision Records

* **ADR 0001** — Apache Kafka as the event streaming backbone.
* **ADR 0002** — Spring Boot for platform microservices.
* **ADR 0003** — PostgreSQL as the MVP persistence layer.
* **ADR 0004** — Docker Compose for local development before Kubernetes.
* **ADR 0005** — The Strimzi operator for Kafka on Kubernetes.

Full records are in [docs/decisions/](docs/decisions/). An ADR records a decision as it was taken at the time and is not rewritten as the platform evolves.

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
scripts/
services/
├─ ingestion-service/
├─ query-service/
└─ telemetry-processor/
```

---

# Long-Term Vision

PulseStream is a reference implementation for modern distributed systems: event-driven microservices, scalable streaming pipelines, cloud-native deployment patterns, and production-grade observability.
