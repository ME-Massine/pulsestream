# PulseStream — Project State

This document is the **authoritative record of the current engineering state** of the PulseStream platform. When `README.md`, `docs/roadmap.md`, or any architecture document disagrees with this file about what exists, this file wins and the other document is the defect.

PulseStream is a cloud-native event processing platform engineered for the ingestion, streaming, processing, and analysis of IoT telemetry events.

**Current phase:** Phase 7 — Production Readiness and Platform Hardening.

---

## Status Vocabulary

Every capability statement in this repository uses one of three words. They are not interchangeable.

| Term | Meaning |
| :--- | :--- |
| **Implemented** | Code, manifests, or configuration are committed to this repository and covered by unit or structural tests. Nothing is claimed about running it. |
| **Validated** | Implemented, *and* exercised end to end against a running platform by a named script or recorded evidence document. The evidence is linked wherever the claim is made. |
| **Planned** | Not implemented. A GitHub issue exists and is linked. |

A capability that is implemented but never run against a live platform is **implemented, not validated**. Documents must not blur the two.

---

## Progress Tracker

| Phase | Description | Status |
| :--- | :--- | :--- |
| **Phase 1** | Architecture and Design | ✅ Complete |
| **Phase 2** | Local Development Platform | ✅ Complete |
| **Phase 3** | Core Event Pipeline | ✅ Complete (read side deferred to Phase 7) |
| **Phase 4** | Observability and Monitoring | ✅ Complete for the local stack |
| **Phase 5** | Reliability and Resilience | ✅ Complete |
| **Phase 6** | Kubernetes Deployment | 🚧 Complete except the in-cluster observability stack ([#32](https://github.com/ME-Massine/pulsestream/issues/32)) |
| **Phase 7** | Production Readiness and Platform Hardening | 🚧 In Progress ([#254](https://github.com/ME-Massine/pulsestream/issues/254)) |

---

## Current Phase

### Phase 7 — Production Readiness and Platform Hardening ([#254](https://github.com/ME-Massine/pulsestream/issues/254))

The platform deploys to Kubernetes, ingests telemetry, processes and persists it, routes failures to a dead-letter queue, and replays them on demand. Phase 7 turns that into something operable and releasable: the read side (query APIs and anomaly projections), enforceable CI quality gates, schema migrations, versioned event contracts, correctness under horizontal scaling, transport and ingestion security, SLOs and runbooks, and a versioned release.

Work is grouped under five sub-parents:

| Parent | Scope |
| :--- | :--- |
| [#255](https://github.com/ME-Massine/pulsestream/issues/255) | Engineering quality and release foundations |
| [#256](https://github.com/ME-Massine/pulsestream/issues/256) | Production data contracts and query capabilities |
| [#257](https://github.com/ME-Massine/pulsestream/issues/257) | Distributed processing correctness and scalability |
| [#258](https://github.com/ME-Massine/pulsestream/issues/258) | Runtime observability, security, and operations |
| [#259](https://github.com/ME-Massine/pulsestream/issues/259) | Release validation and publication |

---

## Implemented Platform Capabilities

### Repository Foundation

GitHub project board, issue forms and pull request templates, contribution guidelines, and a CI workflow, under the MIT license.

### Architecture and Decisions (Phase 1)

Platform overview, service boundaries, event schema, Kafka topic definitions, and a C4 model, in [docs/architecture/](docs/architecture/) and [docs/diagrams/](docs/diagrams/).

Architecture Decision Records in [docs/decisions/](docs/decisions/):

* **ADR 0001** — Apache Kafka as the event streaming backbone.
* **ADR 0002** — Spring Boot for platform microservices.
* **ADR 0003** — PostgreSQL as the MVP persistence layer.
* **ADR 0004** — Docker Compose for local development before Kubernetes.
* **ADR 0005** — Strimzi operator for Kafka on Kubernetes.

### Local Development Platform (Phase 2)

`docker compose up -d` in [infrastructure/docker/](infrastructure/docker/) brings up Kafka, Zookeeper, PostgreSQL, Redis, Prometheus, Grafana, and Jaeger. Topics are provisioned by `infrastructure/docker/kafka/init-topics.sh`; the PostgreSQL schema is created by `infrastructure/docker/postgres/init.sql`. Spring Boot services run from their service directories against that infrastructure.

### Core Event Pipeline (Phase 3)

* `ingestion-service` — `POST /api/v1/events` with request validation and a global exception handler.
* Kafka producer publishing raw telemetry to `telemetry.events.raw`.
* `telemetry-processor` — consumes `telemetry.events.raw`, normalizes, applies anomaly detection.
* Processed events published to `telemetry.events.processed`; anomaly events to `telemetry.events.anomalies`.
* PostgreSQL persistence of normal processed telemetry in `platform.processed_telemetry`, idempotent by unique `event_id` under at-least-once redelivery.

### Observability (Phase 4)

* Spring Boot actuator health and Prometheus endpoints in `ingestion-service` and `telemetry-processor`.
* Prometheus scrape configuration in the local stack, and a Grafana instance provisioned with a Prometheus datasource plus version-controlled dashboards from `observability/grafana/dashboards/`.
* Distributed tracing **implemented**: both services carry the OpenTelemetry Spring Boot starter and export OTLP over `http/protobuf`, to Jaeger locally and to the in-cluster collector on Kubernetes.
* **Validated locally** by `scripts/validate-prometheus-metrics.ps1`, `scripts/validate-grafana-datasource.ps1`, and `scripts/validate-distributed-tracing.ps1` (the last asserting spans from both services land in Jaeger).

### Reliability and Resilience (Phase 5)

* Dead-letter routing from **both** services into `telemetry.events.dlq`, sharing the `DeadLetterEvent` wrapper and identifying themselves through `sourceService`. `ingestion-service` routes an accepted event whose raw-topic publish failed; `telemetry-processor` routes on first processing failure — no retry policy is configured on the listener container, so a processor-sourced record means "failed once", not "retries exhausted".
* DLQ records carry error metadata (failure reason, source service, timestamps).
* Selective DLQ replay: a `dlq-replay-listener` registered with `autoStartup=false`, started and stopped through an actuator endpoint on a management port bound to loopback by default (`9083`/`127.0.0.1`). Only operator-selected `eventId`s are republished to `telemetry.events.raw`; a `start` without a non-empty selection is rejected.
* Replay safeguards: replay markers in Kafka headers, and upsert-by-`event_id` persistence so a replayed projection replaces rather than duplicates.
* **Validated end to end** by `scripts/validate-dlq-pipeline.ps1` and `scripts/validate-event-replay.ps1`. Strategy: [docs/architecture/event-replay-strategy.md](docs/architecture/event-replay-strategy.md).

### Kubernetes Deployment (Phase 6)

* Production Dockerfiles for all three services under a shared build standard, published to a container registry by CI.
* Deployment manifests for `ingestion-service`, `telemetry-processor`, and `query-service`, with liveness and readiness probes, and configuration externalized to ConfigMaps and Secrets.
* Kafka deployed by the Strimzi operator in KRaft mode with persistent storage; platform topics provisioned as `KafkaTopic` resources.
* Internal ClusterIP services plus a NodePort for external ingestion; DNS conventions documented in [infrastructure/kubernetes/service-discovery.md](infrastructure/kubernetes/service-discovery.md).
* NetworkPolicies isolating each service to its required ingress and egress paths.
* Horizontal Pod Autoscalers: CPU-based for `ingestion-service` and `telemetry-processor`, plus a custom-metrics HPA definition for `ingestion-service`.
* An OpenTelemetry Collector in the `observability` namespace receiving OTLP from both instrumented services.
* **Validated** by `scripts/validate-kafka-broker-health.ps1`, `scripts/validate-service-connectivity.ps1`, `scripts/validate-ingestion-external-access.ps1`, `scripts/validate-network-policies.ps1`, and `scripts/validate-autoscaling-behavior.ps1`, with recorded evidence in [docs/architecture/autoscaling-validation.md](docs/architecture/autoscaling-validation.md) and the `hpa-*-runtime-verification.md` notes under `infrastructure/kubernetes/`.

---

## Known Gaps

These are the capabilities a reader might reasonably expect and will not find. Each is either tracked or explicitly untracked.

| Gap | Status |
| :--- | :--- |
| Anomaly records are published to Kafka but never persisted. `platform.anomalies` exists in `init.sql` and is never written by application code | Planned — [#267](https://github.com/ME-Massine/pulsestream/issues/267) |
| `query-service` is a scaffold: application class, configuration, and a context-load test. No endpoints, no data access, no datasource | Planned — [#266](https://github.com/ME-Massine/pulsestream/issues/266) |
| PostgreSQL schema is applied by an init script, not by versioned migrations | Planned — [#265](https://github.com/ME-Massine/pulsestream/issues/265) |
| No consumer-lag or custom processing metrics are exported, so the custom-metrics HPA has no series to scale on and `telemetry-processor` scales on CPU only | Planned — [#272](https://github.com/ME-Massine/pulsestream/issues/272) |
| `ingestion-service` emits no Kafka producer span; its hand-built `ProducerFactory` beans are not auto-instrumented | Bug — [#294](https://github.com/ME-Massine/pulsestream/issues/294) |
| In-cluster Prometheus, Grafana, and tracing backend are not deployed. Traces terminate in the collector's `debug` exporter | Planned — [#32](https://github.com/ME-Massine/pulsestream/issues/32) (Phase 6 carry-over: [#154](https://github.com/ME-Massine/pulsestream/issues/154), [#155](https://github.com/ME-Massine/pulsestream/issues/155), [#156](https://github.com/ME-Massine/pulsestream/issues/156), [#158](https://github.com/ME-Massine/pulsestream/issues/158), [#159](https://github.com/ME-Massine/pulsestream/issues/159)) |
| PostgreSQL itself is not provisioned in Kubernetes. `telemetry-processor` is configured for `postgres:5432` and the NetworkPolicy allows that port, but no manifest creates the workload | Untracked gap |
| External ingestion has no TLS or authentication; Kafka clients are unauthenticated and unencrypted | Planned — [#273](https://github.com/ME-Massine/pulsestream/issues/273), [#275](https://github.com/ME-Massine/pulsestream/issues/275) |
| Anomaly detection is not deterministic under horizontal scaling | Planned — [#269](https://github.com/ME-Massine/pulsestream/issues/269) |
| PostgreSQL and Kafka writes are not transactionally consistent | Planned — [#270](https://github.com/ME-Massine/pulsestream/issues/270) |
| No device simulator exists in the repository | Not scheduled |

---

## Next Immediate Work

Phase 7 opens on the read side and the quality gates, because everything else in the phase is validated through them:

* Complete CI quality gates for every service and infrastructure component ([#262](https://github.com/ME-Massine/pulsestream/issues/262)).
* Version-controlled PostgreSQL schema migrations ([#265](https://github.com/ME-Massine/pulsestream/issues/265)), which the query and anomaly work builds on.
* Processed telemetry query API ([#266](https://github.com/ME-Massine/pulsestream/issues/266)) and anomaly persistence ([#267](https://github.com/ME-Massine/pulsestream/issues/267)).
* Close out the in-cluster observability stack ([#32](https://github.com/ME-Massine/pulsestream/issues/32)) carried over from Phase 6.

---

## Repository Structure

```text
docs/
├─ architecture/
├─ decisions/
├─ diagrams/
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

## Long-Term Vision

PulseStream is designed to serve as a reference implementation for modern distributed systems: event-driven microservices, scalable streaming pipelines, cloud-native deployment patterns, and production-grade observability.
