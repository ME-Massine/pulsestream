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

The repository contains three services: `ingestion-service` and `telemetry-processor` are fully implemented and deployed; `query-service` is a deployed scaffold with no functionality yet. Simulator tooling and additional downstream consumers are not present. Status terms below follow the vocabulary in [`PROJECT_STATE.md`](../../PROJECT_STATE.md#status-vocabulary).

### Ingestion Service

The Ingestion Service is responsible for receiving telemetry events from IoT devices or gateways.

**Responsibilities:**

*   Receive telemetry events via HTTP API
*   Validate event schema
*   Enrich metadata if necessary
*   Publish validated events to Kafka

**Primary Kafka interaction:**

*   Produces events to `telemetry.events.raw`
*   Produces to `telemetry.events.dlq` when a raw-topic publish fails, so an accepted event is not lost

**Key characteristics:**

*   Stateless service
*   Horizontally scalable — CPU-based HPA, 2 to 6 replicas at 70% target utilization
*   First entry point of the platform
*   Instrumented with the OpenTelemetry Spring Boot starter, exporting OTLP over `http/protobuf`

**Status:** Implemented. Externally reachable in Kubernetes through a NodePort with no TLS or authentication in front of it ([#273](https://github.com/ME-Massine/pulsestream/issues/273)).

---

### Telemetry Processor

The telemetry-processor consumes raw telemetry events and performs real-time analysis.

**Responsibilities:**

*   Consume events from Kafka
*   Normalize telemetry data
*   Apply anomaly detection rules
*   Generate anomaly events when necessary
*   Persist processed telemetry records
*   Route processing failures to the dead-letter queue and replay them on operator command

**Primary Kafka interaction:**

*   Consumes from `telemetry.events.raw`
*   Produces to `telemetry.events.processed`
*   Produces to `telemetry.events.anomalies`
*   Produces to `telemetry.events.dlq` on the first processing failure — no retry policy is configured on the listener container
*   Consumes `telemetry.events.dlq` through a `dlq-replay-listener` registered with `autoStartup=false`, and republishes selected events to `telemetry.events.raw`

**Key characteristics:**

*   Streaming consumer
*   Horizontally scalable — CPU-based HPA, 2 to 3 replicas; the ceiling is the topic partition count, not a capacity guess
*   Performs core data processing logic
*   Exposes replay start/stop through an actuator endpoint on a management port bound to loopback by default (`9083`/`127.0.0.1`)
*   Instrumented with the OpenTelemetry Spring Boot starter

**Status:** Implemented. DLQ and replay behaviour is validated end to end by `scripts/validate-dlq-pipeline.ps1` and `scripts/validate-event-replay.ps1`.

---

### Query Service

**Status:** Scaffold. `services/query-service` holds an application class, configuration, and a context-load test. It has a Dockerfile, a published image, and Kubernetes Deployment, Service, and ConfigMap manifests, so the read side has somewhere to land — but there are no REST endpoints, no data access, and no datasource. Its NetworkPolicy allows DNS only for that reason. Tracked by [#266](https://github.com/ME-Massine/pulsestream/issues/266) and [#267](https://github.com/ME-Massine/pulsestream/issues/267).

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

**Status:** Not present in the repository and not currently scheduled. The description below is aspirational.

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

| Component     | Role                                  |
|---------------|---------------------------------------|
| Prometheus    | Collects metrics from service actuator endpoints. Local stack only; not deployed in-cluster ([#154](https://github.com/ME-Massine/pulsestream/issues/154)) |
| Grafana       | Dashboards provisioned from version-controlled JSON in `observability/grafana/dashboards/`. Local stack only ([#155](https://github.com/ME-Massine/pulsestream/issues/155)) |
| OpenTelemetry | Trace instrumentation in both event-path services, plus a collector Deployment in the cluster's `observability` namespace |
| Jaeger        | Trace visualization in the local stack. No trace backend runs in-cluster ([#158](https://github.com/ME-Massine/pulsestream/issues/158)) |

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
| `telemetry.events.raw`      | Raw telemetry events      |
| `telemetry.events.processed`| Normalized telemetry data |
| `telemetry.events.anomalies`| Detected anomalies        |
| `telemetry.events.dlq`| Failed or invalid events  |

---

### PostgreSQL

PostgreSQL stores processed telemetry records. The schema script also defines an `anomalies` table, but the current telemetry processor publishes anomaly events to Kafka and does not persist anomaly records through application code yet.

**Responsibilities:**

*   Persistent storage of processed telemetry history
*   Anomaly tracking — planned ([#267](https://github.com/ME-Massine/pulsestream/issues/267))
*   Query support for dashboards — planned ([#266](https://github.com/ME-Massine/pulsestream/issues/266))

The schema is applied by `infrastructure/docker/postgres/init.sql` rather than by versioned migrations ([#265](https://github.com/ME-Massine/pulsestream/issues/265)). PostgreSQL is **not** provisioned by the Kubernetes manifests; `telemetry-processor` is configured for a `postgres:5432` Service in its namespace.

**Example tables:**

*   `platform.processed_telemetry`
*   `platform.anomalies` (schema exists in `postgres/init.sql`; application persistence is not implemented yet)

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
Ingestion Service ──(publish failure)──> telemetry.events.dlq
↓
Kafka Topic: telemetry.events.raw
↓
telemetry-processor
├─ normal reading      → PostgreSQL + telemetry.events.processed
├─ anomalous reading   → telemetry.events.anomalies
└─ processing failure  → telemetry.events.dlq

Operator-triggered replay:
telemetry.events.dlq → telemetry-processor → telemetry.events.raw

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

**Status:** No autoscaler. `query-service` is a scaffold with no read traffic to scale against, so an HPA would only add moving parts to an idle deployment — see [autoscaling-strategy.md](./autoscaling-strategy.md).

*   Would scale based on query traffic
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
