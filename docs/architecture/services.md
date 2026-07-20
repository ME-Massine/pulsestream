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

The current PulseStream checkout includes the ingestion service and telemetry processor. Query APIs, simulator tooling, tracing, and additional consumers are planned extensions unless noted otherwise.

### Ingestion Service

The Ingestion Service is responsible for receiving telemetry events from IoT devices or gateways.

**Responsibilities:**

*   Receive telemetry events via HTTP API
*   Validate event schema
*   Enrich metadata if necessary
*   Publish validated events to Kafka

**Primary Kafka interaction:**

*   Produces events to `telemetry.events.raw`

**Key characteristics:**

*   Stateless service
*   Horizontally scalable
*   First entry point of the platform

---

### Telemetry Processor

The telemetry-processor consumes raw telemetry events and performs real-time analysis.

**Responsibilities:**

*   Consume events from Kafka
*   Normalize telemetry data
*   Apply anomaly detection rules
*   Generate anomaly events when necessary
*   Persist processed telemetry records

**Primary Kafka interaction:**

*   Consumes from `telemetry.events.raw`
*   Produces to `telemetry.events.processed`
*   Produces to `telemetry.events.anomalies`

**Key characteristics:**

*   Streaming consumer
*   Horizontally scalable
*   Performs core data processing logic

---

### Query Service

**Status:** Scaffold exists at `services/query-service`. Query business functionality (REST endpoints, data access) is still planned.

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

| Component     | Role                                  |
|---------------|---------------------------------------|
| Prometheus    | Collect system and application metrics |
| Grafana       | Visualize metrics and dashboards      |
| OpenTelemetry | Planned distributed tracing instrumentation |
| Jaeger        | Planned trace visualization           |

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
*   Planned anomaly tracking
*   Query support for dashboards

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
IoT Device / Simulator
↓
Ingestion Service
↓
Kafka Topic: telemetry.events.raw
↓
telemetry-processor
├─ normal reading → PostgreSQL + telemetry.events.processed
└─ anomalous reading → telemetry.events.anomalies

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

**Status:** Planned.

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
