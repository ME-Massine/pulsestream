# Service Architecture

## Overview

PulseStream follows a microservice-oriented architecture where each service has a clearly defined responsibility. Services communicate asynchronously through Kafka events, reducing direct dependencies between components.

This document describes the core services that make up the PulseStream platform and their responsibilities.

---

## Service Architecture Principles

The platform follows several service design principles:

### Single Responsibility

Each service is responsible for a specific capability in the telemetry processing pipeline.

### Event-Driven Communication

Services exchange information through Kafka topics instead of synchronous service-to-service calls whenever possible.

### Loose Coupling

Services remain independent of each other's internal implementation. Communication occurs through well-defined event schemas.

### Horizontal Scalability

Each service can scale independently depending on workload demands.

---

## Core Services

The current PulseStream checkout includes the ingestion service, the telemetry processor, and a `query-service` scaffold. Distributed tracing is implemented in the two stream-path services. Query APIs, simulator tooling, and downstream consumers of `processed` and `anomalies` are planned extensions unless noted otherwise.

Status words used below — **Planned**, **Implemented**, **Validated** — are defined in [`PROJECT_STATE.md`](../../PROJECT_STATE.md#how-to-read-status-in-this-repository), which is the authoritative record of platform status.

### Ingestion Service

The Ingestion Service is responsible for receiving telemetry events from IoT devices or gateways.

**Responsibilities:**

*   Receive telemetry events via HTTP API
*   Validate event schema
*   Enrich metadata if necessary
*   Publish validated events to Kafka
*   Route publish failures to the dead-letter topic, enriched with error metadata

**Primary Kafka interaction:**

*   Produces events to `telemetry.events.raw`
*   Produces to `telemetry.events.dlq` when a publish to `raw` fails

**Key characteristics:**

*   Stateless service
*   Horizontally scalable, with a CPU-based HPA on Kubernetes
*   First entry point of the platform
*   Instrumented with OpenTelemetry; exports OTLP over `http/protobuf`
*   Unauthenticated and unencrypted today ([#273](https://github.com/ME-Massine/pulsestream/issues/273))

---

### Telemetry Processor

The telemetry-processor consumes raw telemetry events and performs real-time analysis.

**Responsibilities:**

*   Consume events from Kafka
*   Normalize telemetry data
*   Apply anomaly detection rules
*   Generate anomaly events when necessary
*   Persist normal processed telemetry records
*   Route processing failures to the dead-letter topic
*   Perform bounded, operator-selected replay from the dead-letter topic

**Primary Kafka interaction:**

*   Consumes from `telemetry.events.raw` in the `telemetry-processor` group
*   Produces to `telemetry.events.processed`
*   Produces to `telemetry.events.anomalies`
*   Produces to `telemetry.events.dlq` on processing failure
*   Consumes `telemetry.events.dlq` in the separate `telemetry-processor-dlq-replay` group during replay, republishing selected events to `telemetry.events.raw`

**Key characteristics:**

*   Streaming consumer
*   Horizontally scalable, with a CPU-based HPA on Kubernetes bounded by the partition count of `telemetry.events.raw`
*   Performs core data processing logic
*   Instrumented with OpenTelemetry; exports OTLP over `http/protobuf`
*   Serves its actuator surface — including the state-changing `dlqreplay` endpoint — on a separate management port bound to loopback by default, with only the liveness and readiness probe groups mirrored onto the main server port
*   Anomaly-detection state is held per replica, so detection results depend on partition assignment ([#269](https://github.com/ME-Massine/pulsestream/issues/269))

---

### Query Service

**Status:** Scaffold only.

What exists today at `services/query-service`: a Spring Boot application class, `application.yml` with actuator `health`, `info` and `prometheus` endpoints and Kubernetes probe groups, a production Dockerfile, and Kubernetes manifests ([`infrastructure/kubernetes/query-service/`](../../infrastructure/kubernetes/query-service/)) including a default-deny NetworkPolicy. It deploys and reports healthy.

What does not exist: controllers, repositories, any data access, any query endpoint, and any OpenTelemetry configuration — the service emits no spans, so it is deliberately not wired to the collector. Query functionality is tracked by [#266](https://github.com/ME-Massine/pulsestream/issues/266) and [#267](https://github.com/ME-Massine/pulsestream/issues/267).

The sections below describe the **planned** design.

The Query Service exposes APIs that allow external systems and dashboards to retrieve telemetry data and anomalies.

**Responsibilities:**

*   Expose REST APIs
*   Query processed telemetry data
*   Retrieve anomaly records
*   Support filtering and aggregation queries

**Primary data interaction:**

*   Reads from PostgreSQL

**Key characteristics:**

*   Read-oriented service
*   Optimized for data retrieval
*   Supports monitoring dashboards

---

### Device Simulator

**Status:** Planned. There is no simulator service or script in the current checkout.

The Device Simulator generates synthetic telemetry events to simulate IoT devices during development and testing.

**Responsibilities:**

*   Simulate multiple device streams
*   Generate telemetry readings
*   Introduce anomaly scenarios
*   Stress test the ingestion pipeline

**Primary Kafka interaction:**

*   Produces telemetry events to the ingestion API

**Key characteristics:**

*   Development and testing tool
*   Configurable device count and telemetry frequency

---

### Observability Components

PulseStream integrates observability tools to monitor system health and performance.

**Key components:**

| Component | Role | Status |
|---|---|---|
| Prometheus | Collect system and application metrics | Implemented under Docker Compose; not deployed in the cluster ([#154](https://github.com/ME-Massine/pulsestream/issues/154)) |
| Grafana | Visualize metrics and dashboards | Datasource and dashboard provisioning implemented under Docker Compose; not deployed in the cluster ([#155](https://github.com/ME-Massine/pulsestream/issues/155), [#156](https://github.com/ME-Massine/pulsestream/issues/156)) |
| OpenTelemetry | Distributed tracing instrumentation in `ingestion-service` and `telemetry-processor`; W3C `tracecontext` and `baggage` propagation; OTLP over `http/protobuf` | Implemented; validated under Docker Compose |
| OpenTelemetry Collector | Receives OTLP in the cluster's `observability` namespace | Implemented; traces terminate in its `debug` exporter |
| Jaeger | Trace visualization | Implemented under Docker Compose; no trace backend in the cluster ([#158](https://github.com/ME-Massine/pulsestream/issues/158)) |

**Responsibilities:**

*   Monitor service performance
*   Track event throughput
*   Observe system latency
*   Support debugging of distributed flows

---

## Supporting Infrastructure

Several infrastructure components support the core services.

### Kafka Cluster

Kafka acts as the backbone of the platform.

**Responsibilities:**

*   Event transport
*   Buffering of telemetry streams
*   Decoupling producers and consumers
*   Enabling event replay

**Kafka topics used in the platform:**

| Topic                | Description               |
|----------------------|---------------------------|
| `telemetry.events.raw`      | Raw telemetry events, and the target of dead-letter replay |
| `telemetry.events.processed`| Normalized telemetry data. No committed consumer yet |
| `telemetry.events.anomalies`| Detected anomalies. No committed consumer yet |
| `telemetry.events.dlq`| Failed events from both services, enriched with error metadata. Consumed by the processor's replay listener |

---

### PostgreSQL

PostgreSQL stores normal processed telemetry records. The schema script also defines an `anomalies` table, but the telemetry processor publishes anomaly events to Kafka and does not persist anomaly records through application code ([#267](https://github.com/ME-Massine/pulsestream/issues/267)).

**Responsibilities:**

*   Persistent storage of processed telemetry history
*   Planned anomaly tracking
*   Planned query support for dashboards

**Tables:**

*   `platform.processed_telemetry` — written by `ProcessedTelemetryPersistenceService`
*   `platform.anomalies` — defined in `postgres/init.sql`; no application code writes to it

**Current limitations:**

*   The schema is applied by an init script under Docker Compose, not by versioned migrations ([#265](https://github.com/ME-Massine/pulsestream/issues/265)).
*   No PostgreSQL manifest is committed for Kubernetes. The service ConfigMaps address `postgres:5432`, which must be provisioned out of band.
*   The Kafka publish and the database write are separate operations and are not atomic ([#270](https://github.com/ME-Massine/pulsestream/issues/270)).

---

### Redis (Optional)

Redis may be used as a caching layer.

**Potential use cases:**

*   Caching frequent query results
*   Temporary device state storage
*   Rate limiting

Redis is optional in the MVP architecture.

---

## Service Interaction Model

Services interact primarily through Kafka topics.

**Event flow:**

```bash
IoT Device
↓
Ingestion Service ──(publish failure)──→ telemetry.events.dlq
↓
Kafka Topic: telemetry.events.raw ←──(selective replay)──┐
↓                                                        │
telemetry-processor                                      │
├─ normal reading    → PostgreSQL + telemetry.events.processed
├─ anomalous reading → telemetry.events.anomalies
└─ processing failure → telemetry.events.dlq ────────────┘

Planned follow-up:
PostgreSQL / Kafka topics → Query Service → Dashboard / Clients
```

This asynchronous interaction model allows services to scale and evolve independently.

---

## Service Scaling Strategy

Each service can scale horizontally depending on system load.

### Ingestion Service

*   Scales based on incoming request volume
*   Stateless design enables easy scaling

### Telemetry Processor

*   Scales by increasing Kafka consumer instances
*   Partition-based parallel processing

### Query Service

**Status:** Scaffold. The Deployment exists and can be scaled, but the service does no work.

*   Scales based on query traffic
*   Read replicas may be introduced later

---

## Future Services

The platform may evolve to include additional services:

**Possible future components:**

*   Alert notification service
*   Device management service
*   Advanced anomaly detection engine
*   Machine learning inference service

These extensions would integrate with the existing event pipeline.

---

## Summary

The PulseStream service architecture separates responsibilities across specialized components that interact through an event streaming backbone.

This design provides:

*   Scalability
*   Loose coupling
*   Resilience
*   Real-time processing capabilities
