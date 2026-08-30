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

The platform runs three Spring Boot services: `ingestion-service` and `telemetry-processor` are fully implemented, and `query-service` is a scaffold with actuator endpoints and no business functionality. Metrics and distributed tracing are implemented; a device simulator and downstream consumers of the processed and anomaly topics are planned. Per-capability status is in [PROJECT_STATE.md](../../PROJECT_STATE.md).

### Ingestion Service

The Ingestion Service is responsible for receiving telemetry events from IoT devices or gateways.

**Responsibilities:**

*   Receive telemetry events via `POST /api/v1/events`
*   Validate the event schema and return structured errors for invalid requests
*   Publish validated events to Kafka
*   Preserve accepted events that could not be published, by routing them to the dead-letter topic

**Primary Kafka interaction:**

*   Produces events to `telemetry.events.raw`
*   Produces `DeadLetterEvent` records to `telemetry.events.dlq` when a publish fails, tagged `sourceService: ingestion-service`

**Key characteristics:**

*   Stateless service
*   Horizontally scalable, with CPU-based and request-rate custom-metric HPAs in Kubernetes
*   First entry point of the platform
*   Exposes actuator `health`, `info` and `prometheus` on port 8081, and is the platform's Prometheus scrape target in both environments
*   Instrumented with OpenTelemetry for HTTP server spans and W3C context propagation. The Kafka producer path is **not** instrumented, so traces stop at the HTTP boundary (#294)
*   Unauthenticated. Securing external ingestion is planned (#273)

---

### Telemetry Processor

The telemetry-processor consumes raw telemetry events and performs real-time analysis.

**Responsibilities:**

*   Consume events from Kafka
*   Normalize telemetry data
*   Apply anomaly detection rules
*   Generate anomaly events when necessary
*   Persist normal processed telemetry records, upserting by `event_id`
*   Dead-letter events it cannot process, and replay selected dead-letter events on operator request

**Primary Kafka interaction:**

*   Consumes from `telemetry.events.raw`
*   Produces to `telemetry.events.processed`
*   Produces to `telemetry.events.anomalies`
*   Produces `DeadLetterEvent` records to `telemetry.events.dlq` on a processing failure, tagged `sourceService: telemetry-processor`
*   Consumes from `telemetry.events.dlq` during a replay run, and republishes the selected events to `telemetry.events.raw`

**Key characteristics:**

*   Streaming consumer
*   Horizontally scalable, with a CPU-based HPA in Kubernetes. Anomaly detection state is per-instance, so results are not yet deterministic beyond one replica (#269)
*   Performs core data processing logic
*   **No retry policy** on the listener container: a processing failure dead-letters on the first attempt
*   Serves its actuator surface on a separate management port (`9083`) bound to loopback, because the `dlqreplay` endpoint is state-changing and unauthenticated. As a result the processor is **not** a Prometheus scrape target in either environment
*   Only normal readings are persisted; detected anomalies are published to Kafka and not written to the database (#267)

---

### Query Service

**Status:** Scaffold only. `services/query-service` is a Spring Boot application exposing actuator `health`, `info` and `prometheus` on port 8083, with a production Dockerfile and Kubernetes Deployment, Service and ConfigMap manifests. It has **no REST endpoints and no database access**: it runs, is scraped by Prometheus, and does nothing else. The query API is #266 and anomaly querying is #267.

The responsibilities below describe the intended service, not current behaviour.

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

| Component     | Role                                  | Status |
|---------------|---------------------------------------|--------|
| Prometheus    | Collect system and application metrics | Deployed locally and in cluster |
| Grafana       | Visualize metrics and dashboards      | Dashboards provisioned locally; base deployment in cluster without a datasource yet (#156) |
| OpenTelemetry | Distributed tracing instrumentation and in-cluster collection | Instrumentation implemented in both services; Collector deployed in the `observability` namespace |
| Jaeger        | Trace visualization                   | Runs in the local Compose stack; no in-cluster backend yet (#158) |

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

PostgreSQL stores processed telemetry records. The schema script also defines an `anomalies` table, but the telemetry processor publishes anomaly events to Kafka and does not persist anomaly records through application code (#267).

The schema is created by `infrastructure/docker/postgres/init.sql` with Hibernate `ddl-auto: none`. There is no versioned migration tool (#265). No PostgreSQL manifests exist for Kubernetes: the processor's ConfigMap points at a `postgres` Service that must be supplied out of band.

**Responsibilities:**

*   Persistent storage of processed telemetry history
*   Planned anomaly tracking
*   Query support for dashboards

**Tables:**

*   `platform.processed_telemetry` — written by the processor, upserted by `event_id`
*   `platform.anomalies` — defined in `postgres/init.sql`, unused by application code (#267)

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
Ingestion Service
├─ publish succeeds → telemetry.events.raw
└─ publish fails    → telemetry.events.dlq
↓
telemetry-processor
├─ normal reading    → PostgreSQL + telemetry.events.processed
├─ anomalous reading → telemetry.events.anomalies only (not persisted, not published as processed)
└─ processing throws → telemetry.events.dlq

Operator-triggered replay:
telemetry.events.dlq → selected eventIds → telemetry.events.raw

Planned follow-up:
PostgreSQL / Kafka topics → Query Service → Dashboard / Clients
```

This asynchronous interaction model allows services to scale and evolve independently.

---

## Service Scaling Strategy

Each service can scale horizontally depending on system load. In Kubernetes this is driven by HorizontalPodAutoscalers; the reasoning behind the thresholds and behaviour windows is in [autoscaling-strategy.md](./autoscaling-strategy.md), and the end-to-end results in [autoscaling-validation.md](./autoscaling-validation.md).

### Ingestion Service

*   Scales on CPU and on a request-rate custom metric served through `prometheus-adapter`
*   Stateless design enables easy scaling

### Telemetry Processor

*   Scales on CPU. Consumer lag is the signal this workload actually wants, but it is not exported yet (#272)
*   Partition-based parallel processing, bounded by the topic partition count
*   Anomaly detection state is per-instance, so detection results are not deterministic beyond one replica (#269)

### Query Service

**Status:** Scaffold. No HPA is defined, and there is no query traffic to scale on.

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
