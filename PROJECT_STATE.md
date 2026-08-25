# PulseStream — Project State

**This document is the authoritative source for the current status of the PulseStream platform.**

Where this file disagrees with any other document, this file is correct and the other document is stale. [`README.md`](README.md) and [`docs/roadmap.md`](docs/roadmap.md) summarise the same state for different audiences and are kept in sync with it; per-area detail lives in [`docs/architecture/`](docs/architecture/) and in the `README.md` next to each manifest directory under [`infrastructure/kubernetes/`](infrastructure/kubernetes/). GitHub issues are the authoritative source for *planned* work; this file is the authoritative source for what is *built*.

PulseStream is a cloud-native event processing platform for the ingestion, streaming, processing, and analysis of IoT telemetry events.

---

## How to read status in this repository

Every capability described in PulseStream documentation is in exactly one of three states. The same three words are used in `README.md`, `docs/roadmap.md`, `docs/architecture/`, and `docs/diagrams/`.

| Status | Meaning |
| :--- | :--- |
| **Planned** | Described in documentation or an issue. No implementation is committed. |
| **Implemented** | Code or manifests are committed and reviewed. The behaviour has not been exercised end to end against a running system in the environment named. |
| **Validated** | Implemented, plus exercised end to end against a running system by a repeatable procedure committed under [`scripts/`](scripts/) or documented in a manifest `README.md`. |

**Validation is environment-specific.** A capability validated under Docker Compose is not thereby validated on Kubernetes. Where the distinction matters, the environment is named.

---

## Progress Tracker

| Phase | Description | Status |
| :--- | :--- | :--- |
| **Phase 1** | Architecture and Design | ✅ Complete |
| **Phase 2** | Local Development Platform | ✅ Complete |
| **Phase 3** | Core Event Pipeline | ✅ Complete — read-side work re-scoped to Phase 7 |
| **Phase 4** | Observability and Monitoring | ✅ Complete under Docker Compose — in-cluster stack open under Phase 6 |
| **Phase 5** | Reliability and Resilience | ✅ Complete — validated under Docker Compose |
| **Phase 6** | Kubernetes Deployment | 🚧 In progress — deployment complete, in-cluster observability outstanding |
| **Phase 7** | Production Readiness and Platform Hardening | 🚧 In progress — current phase |

---

# Current Phase

### Phase 7 — Production Readiness and Platform Hardening ([#254](https://github.com/ME-Massine/pulsestream/issues/254))

Phase 7 turns the deployable platform into a secure, operable, versioned release. Its scope covers CI quality gates, supply-chain security, schema migrations, the telemetry and anomaly query APIs, versioned event contracts, distributed-processing correctness, ingestion and Kafka security, SLOs and runbooks, load and durability validation, and a published versioned release.

Phase 7 began with a documented remainder of Phase 6 still open. That is permitted by the Phase 7 entry criteria, which require the Kubernetes observability and autoscaling work to be *complete or explicitly re-scoped*. It is re-scoped, and it is listed under [Outstanding Phase 6 work](#outstanding-phase-6-work) rather than being folded silently into Phase 7.

---

# Implemented Platform Capabilities

Everything in this section is committed in the current checkout.

### Repository Foundation (Phase 1)

GitHub project board, issue forms for tasks, features and bugs, a pull request template, contribution guidelines, a CI workflow, and a PR/issue alignment workflow, under the MIT license.

### Architecture and Decision Records (Phase 1)

Platform overview, service boundaries, event schema, topic definitions, and a C4 model, in [`docs/architecture/`](docs/architecture/) and [`docs/diagrams/`](docs/diagrams/).

Accepted ADRs in [`docs/decisions/`](docs/decisions/):

*   **ADR 0001** — Apache Kafka as the event streaming backbone.
*   **ADR 0002** — Spring Boot for platform microservices.
*   **ADR 0003** — PostgreSQL as the MVP persistence layer.
*   **ADR 0004** — Docker Compose for local development before Kubernetes.
*   **ADR 0005** — The Strimzi operator for running Kafka on Kubernetes.

### Local Development Platform (Phase 2)

A single command brings up the shared infrastructure defined in [`infrastructure/docker/docker-compose.yml`](infrastructure/docker/docker-compose.yml):

```bash
docker compose up -d
```

The stack provides Kafka, Zookeeper, PostgreSQL (schema initialised from [`postgres/init.sql`](infrastructure/docker/postgres/init.sql)), Redis, Prometheus, Grafana, and Jaeger. The three Spring Boot services run from their own directories on the host against it.

### Core Event Pipeline (Phase 3)

*   `ingestion-service` — `POST /api/v1/events` with request validation and a global exception handler.
*   Kafka producer publishing raw telemetry to `telemetry.events.raw` with `acks=all` and bounded delivery and publish timeouts.
*   `telemetry-processor` — Kafka consumer on `telemetry.events.raw`, telemetry normalization, threshold-based anomaly detection.
*   Processed events published to `telemetry.events.processed`; anomaly events to `telemetry.events.anomalies`.
*   PostgreSQL persistence of normal processed telemetry in `platform.processed_telemetry`.
*   `query-service` — **scaffold only.** A Spring Boot application with actuator and Prometheus endpoints, a production Dockerfile, and Kubernetes manifests. It has no controllers, no repositories, and no data access, and it serves no query endpoints.

### Observability (Phase 4)

*   Actuator `health`, `info` and `prometheus` endpoints in all three services.
*   Kubernetes probe groups enabled and mirrored to `/livez` and `/readyz` on the main server port, so probes never depend on the aggregate health endpoint.
*   Local Prometheus scrape configuration and Grafana datasource/dashboard provisioning under [`infrastructure/docker/`](infrastructure/docker/).
*   **Distributed tracing is implemented, not planned.** `ingestion-service` and `telemetry-processor` carry the OpenTelemetry Spring Boot starter, propagate W3C `tracecontext` and `baggage`, export OTLP over `http/protobuf`, and emit `trace_id` / `span_id` in their log pattern. Validated against Jaeger under Docker Compose by [`scripts/validate-distributed-tracing.ps1`](scripts/validate-distributed-tracing.ps1).
*   `query-service` is **not** instrumented for tracing. It has no `otel` configuration and emits no spans.

### Reliability and Resilience (Phase 5)

*   **Dead-letter routing is implemented.** `ingestion-service` routes publish failures to `telemetry.events.dlq` enriched with error metadata; `telemetry-processor` routes failed processing events to the same topic. Validated under Docker Compose by [`scripts/validate-dlq-pipeline.ps1`](scripts/validate-dlq-pipeline.ps1).
*   **Event replay is implemented.** A bounded, selective replay reads `telemetry.events.dlq` and republishes only operator-selected `eventId`s to `telemetry.events.raw`, carrying replay headers, bounded by the per-partition end offsets captured when replay is triggered, with an idle-timeout fallback. Scope and semantics are in [`docs/architecture/event-replay-strategy.md`](docs/architecture/event-replay-strategy.md); validated under Docker Compose by [`scripts/validate-event-replay.ps1`](scripts/validate-event-replay.ps1).
*   Replay is triggered through the `dlqreplay` actuator endpoint. Because it is state-changing and unauthenticated, the entire management surface of `telemetry-processor` is served on a separate port (`9083`) bound to loopback by default.
*   Producer-side retries and bounded timeouts in both services; Kafka buffering isolates ingestion from downstream processing failures.

### Kubernetes Deployment (Phase 6)

Manifests live under [`infrastructure/kubernetes/`](infrastructure/kubernetes/). They are committed, have been applied against a live cluster, and are covered by the validation scripts named below.

*   Deployments for `ingestion-service`, `telemetry-processor` and `query-service`, with liveness and readiness probes, resource requests and limits, and pinned images.
*   Configuration externalised through ConfigMaps; secrets provisioned out of band, with only a `secret.example.yaml` shape committed.
*   Kafka deployed by the Strimzi operator in KRaft mode with persistent storage and declaratively provisioned platform topics. Validated by [`scripts/validate-kafka-kubernetes.ps1`](scripts/validate-kafka-kubernetes.ps1) and [`scripts/validate-kafka-broker-health.ps1`](scripts/validate-kafka-broker-health.ps1).
*   Internal ClusterIP services and documented DNS conventions in [`infrastructure/kubernetes/service-discovery.md`](infrastructure/kubernetes/service-discovery.md). Validated by [`scripts/validate-service-connectivity.ps1`](scripts/validate-service-connectivity.ps1).
*   External ingestion exposed via NodePort. Validated by [`scripts/validate-ingestion-external-access.ps1`](scripts/validate-ingestion-external-access.ps1).
*   Default-deny NetworkPolicies per service. Validated by [`scripts/validate-network-policies.ps1`](scripts/validate-network-policies.ps1).
*   CPU-based HPAs for `ingestion-service` and `telemetry-processor`, plus a custom-metrics path through the Prometheus adapter. Reasoning in [`docs/architecture/autoscaling-strategy.md`](docs/architecture/autoscaling-strategy.md) and [`docs/architecture/custom-metrics-autoscaling.md`](docs/architecture/custom-metrics-autoscaling.md).
*   An OpenTelemetry Collector in the `observability` namespace receiving OTLP from the two instrumented services. **Traces terminate in the collector's `debug` exporter** — no trace backend runs in the cluster yet.
*   Service images built to a common standard and published to a container registry, with local image validation in [`scripts/validate-container-images.ps1`](scripts/validate-container-images.ps1).

---

# Known Gaps

These are real, current limitations. No document in this repository should describe them as done.

### Outstanding Phase 6 work

| Gap | Tracking |
| :--- | :--- |
| Prometheus is not deployed in the cluster | [#154](https://github.com/ME-Massine/pulsestream/issues/154) |
| Grafana is not deployed in the cluster | [#155](https://github.com/ME-Massine/pulsestream/issues/155) |
| No Grafana datasource or dashboards in the cluster | [#156](https://github.com/ME-Massine/pulsestream/issues/156) |
| No trace backend in the cluster; collector traces end in `debug` | [#158](https://github.com/ME-Massine/pulsestream/issues/158) |
| In-cluster observability not validated end to end | [#159](https://github.com/ME-Massine/pulsestream/issues/159) |
| Autoscaling behaviour not validated end to end under load | [#153](https://github.com/ME-Massine/pulsestream/issues/153) |
| **No PostgreSQL manifest is committed.** Service ConfigMaps address `postgres:5432`, so that Service must be provisioned out of band before the persistence path works in-cluster | [#26](https://github.com/ME-Massine/pulsestream/issues/26) |

### Platform gaps carried into Phase 7

| Gap | Tracking |
| :--- | :--- |
| Anomalies are published to Kafka but never persisted. `platform.anomalies` exists in `init.sql`; no repository writes to it | [#267](https://github.com/ME-Massine/pulsestream/issues/267) |
| `query-service` is a scaffold — no query endpoints exist | [#266](https://github.com/ME-Massine/pulsestream/issues/266) |
| The PostgreSQL schema is applied by an init script, not by versioned migrations | [#265](https://github.com/ME-Massine/pulsestream/issues/265) |
| Event contracts are unversioned and not compatibility-checked | [#268](https://github.com/ME-Massine/pulsestream/issues/268) |
| Anomaly-detection state is per-replica, so horizontal scaling changes detection results | [#269](https://github.com/ME-Massine/pulsestream/issues/269) |
| The Kafka publish and the PostgreSQL write are not atomic | [#270](https://github.com/ME-Massine/pulsestream/issues/270) |
| Replayed events are reprocessed without reclassification or projection guarantees | [#271](https://github.com/ME-Massine/pulsestream/issues/271) |
| No custom processing or consumer-lag metrics | [#272](https://github.com/ME-Massine/pulsestream/issues/272) |
| External ingestion has no TLS and no authentication | [#273](https://github.com/ME-Massine/pulsestream/issues/273) |
| Kafka client traffic is unauthenticated and unencrypted | [#275](https://github.com/ME-Massine/pulsestream/issues/275) |
| No SLOs, alerts, or runbooks | [#276](https://github.com/ME-Massine/pulsestream/issues/276) |
| No load, failure-recovery, or durability evidence | [#277](https://github.com/ME-Massine/pulsestream/issues/277) |
| No versioned release, SBOM, or documented upgrade and rollback path | [#278](https://github.com/ME-Massine/pulsestream/issues/278) |
| No device simulator exists in any form | Long-term backlog |
| Redis is provisioned but unused by application code | Long-term backlog |

---

# Issue Hierarchy

Phase 7 work is tracked as a three-level tree. Every Phase 7 issue is a sub-issue of a workstream, and every workstream is a sub-issue of the phase.

```text
#254  Phase 7 — Production Readiness and Platform Hardening
├─ #255  Engineering quality and release foundations
│  ├─ #261  Synchronize roadmap, project state, diagrams, and issue hierarchy
│  ├─ #262  Enforce complete CI quality gates for all platform components
│  ├─ #263  Add automated repository and software supply-chain security
│  └─ #264  Define versioned release and container image promotion workflow
├─ #256  Deliver production data contracts and query capabilities
│  ├─ #265  Introduce version-controlled PostgreSQL schema migrations
│  ├─ #266  Implement processed telemetry query API
│  ├─ #267  Persist and query detected anomalies
│  └─ #268  Add versioned event contracts and compatibility validation
├─ #257  Harden distributed processing correctness and scalability
│  ├─ #269  Make anomaly detection deterministic under horizontal scaling
│  ├─ #270  Guarantee PostgreSQL and Kafka delivery consistency
│  └─ #271  Correct replay reclassification and projection consistency
├─ #258  Establish runtime observability, security, and operations
│  ├─ #272  Add custom processing and consumer-lag metrics
│  ├─ #273  Secure external telemetry ingestion
│  ├─ #275  Secure Kafka communication and production secrets
│  └─ #276  Define platform SLOs, alerts, and operational runbooks
└─ #259  Validate and publish the production-ready release
   ├─ #277  Validate load, failure recovery, and data durability
   └─ #278  Publish the first versioned PulseStream release
```

Phase 6 ([#26](https://github.com/ME-Massine/pulsestream/issues/26)) stays open for [#31](https://github.com/ME-Massine/pulsestream/issues/31) and [#32](https://github.com/ME-Massine/pulsestream/issues/32) only, whose remaining implementation issues are #153 through #159.

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
├─ docker/          Docker Compose local platform
└─ kubernetes/      Deployments, Kafka (Strimzi), networking, autoscaling, collector

observability/      Shared observability assets

scripts/            Validation procedures and their structural tests

services/
├─ ingestion-service
├─ telemetry-processor
└─ query-service    (scaffold)
```

---

# Long-Term Vision

PulseStream is a reference implementation of a modern distributed system: event-driven microservices, scalable streaming pipelines, cloud-native deployment, and production-grade observability. Beyond Phase 7, candidate directions are time-series-optimised storage, stream processing with Kafka Streams or Flink, multi-tenant telemetry isolation, device fleet management, and machine-learning anomaly detection.
