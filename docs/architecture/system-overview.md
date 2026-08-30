# PulseStream — System Overview

## Introduction

PulseStream is a cloud-native distributed platform designed to ingest, process, and analyze IoT telemetry events in real time. The platform focuses on scalable event processing and anomaly detection using modern cloud-native architecture patterns.

IoT devices continuously generate telemetry data such as temperature, humidity, vibration, and other operational metrics. Traditional systems often struggle to process these streams at scale while maintaining reliability and observability.

PulseStream addresses this challenge by using an event-driven architecture built around distributed streaming and asynchronous processing.

This document describes the architecture and marks what is built against what is intended. [PROJECT_STATE.md](../../PROJECT_STATE.md) is the authoritative record of platform status; where the two disagree, that file is correct.

---

## Objectives

The platform aims to demonstrate the following engineering principles:

- Distributed event-driven architecture
- Real-time stream processing
- Scalable telemetry ingestion
- Automated anomaly detection
- Cloud-native infrastructure and deployment
- Observability and monitoring

---

## Core Capabilities

PulseStream provides several key capabilities:

### Telemetry Ingestion

IoT devices or gateways send telemetry events to the platform via an ingestion API. These events are validated and forwarded to the streaming backbone.

### Real-Time Stream Processing

Telemetry events are processed asynchronously through Kafka consumers. Processing services normalize data, detect anomalies, and derive useful metrics.

### Anomaly Detection

The platform analyzes telemetry streams and detects abnormal device behavior such as:

- threshold breaches
- abnormal spikes or drops in sensor values
- missing device heartbeats

Detection is threshold-based. Detected anomalies are emitted as dedicated Kafka events on `telemetry.events.anomalies` and nothing consumes them yet. The database schema includes an `anomalies` table, but application-level anomaly persistence is not implemented (#267).

### Data Persistence

Normal processed telemetry readings are stored in PostgreSQL, upserted by `event_id`, for historical querying and analytics. Anomalous readings are not persisted.

### Failure Handling and Replay

Events that cannot be published by the ingestion service, or cannot be processed by the telemetry processor, are routed to `telemetry.events.dlq` as `DeadLetterEvent` records carrying error metadata and the service that produced them. An operator can replay a chosen set of dead-letter events back into `telemetry.events.raw` through an actuator endpoint; the run is selective and bounded by end offsets snapshotted at trigger time, and replayed events carry markers that keep persistence idempotent. See [event-replay-strategy.md](./event-replay-strategy.md).

### Query APIs

Dedicated query APIs are planned (#266). `services/query-service` exists as a Spring Boot scaffold with actuator endpoints and container and Kubernetes manifests, but exposes no REST endpoints and performs no database access.

### Observability

All three services expose actuator health, info and Prometheus endpoints, and both processing services are instrumented with OpenTelemetry using W3C context propagation over OTLP. Prometheus and Grafana run locally and in cluster; Jaeger runs locally. Two gaps remain: no Kafka producer span, so traces stop at the HTTP boundary (#294), and no consumer-lag or custom processing metric (#272).

### Cluster Deployment

The platform deploys to Kubernetes: Deployments, Services and ConfigMaps for all three services, Kafka in KRaft mode via the Strimzi operator, ClusterIP service discovery with a NodePort for external ingestion, NetworkPolicies, and horizontal autoscaling on CPU and on a Prometheus custom metric. PostgreSQL is not provisioned in cluster and must be supplied out of band.

---

## High-Level Architecture

The platform is composed of several distributed components that communicate through an event streaming backbone.

### Main Components

| Component | Description |
|----------|-------------|
| Ingestion Service | Accepts telemetry events from devices, publishes them to Kafka, and dead-letters what it cannot publish |
| Kafka Cluster | Central streaming backbone responsible for event transport and buffering |
| Telemetry Processor | Consumes telemetry streams, normalizes, detects anomalies, persists normal readings, dead-letters failures and performs replay |
| Query Service | Scaffold only — actuator endpoints, no REST API and no database access (#266) |
| PostgreSQL | Stores processed telemetry; the `anomalies` table exists in the schema script but is unused (#267) |
| Observability Stack | Prometheus, Grafana, OpenTelemetry and Jaeger locally; Prometheus, Grafana and an OpenTelemetry Collector in cluster |
| Device Simulator | Planned generator for synthetic telemetry; none exists in this repository |

---

## Event Flow

The typical lifecycle of a telemetry event follows this sequence:

```text
IoT Device
↓
Ingestion Service ──(publish failure)──> telemetry.events.dlq
↓
Kafka Topic: telemetry.events.raw
↓
Telemetry Processor ──(processing failure)──> telemetry.events.dlq
├─ normal reading    → telemetry.events.processed + PostgreSQL
└─ anomalous reading → telemetry.events.anomalies

Operator-triggered replay:
telemetry.events.dlq ──(selected eventIds)──> telemetry.events.raw

Planned:
PostgreSQL → Query Service (#266) → Dashboard / API Clients
```

The two processing outcomes are exclusive: an anomalous reading is published to the anomalies topic only, and is not persisted or republished as processed telemetry. Nothing consumes the processed or anomalies topics today.

---

## Technology Stack

PulseStream uses the following core technologies:

| Technology | Purpose |
|-----------|--------|
| Spring Boot | Microservice framework |
| Apache Kafka | Event streaming platform |
| PostgreSQL | Persistent storage for processed data |
| Redis | Optional caching layer; provisioned locally and unused by any service |
| Docker | Containerization for local development and service images |
| Kubernetes | Cluster deployment target: service manifests, Strimzi Kafka, NetworkPolicies and autoscaling |
| Prometheus | Metrics collection, and the metric source for custom autoscaling |
| Grafana | Observability dashboards |
| OpenTelemetry | Distributed tracing instrumentation and in-cluster collection |
| Jaeger | Trace backend in the local stack |

---

## Architectural Principles

PulseStream is designed around several architectural principles:

### Event-Driven Design

Services communicate asynchronously using events instead of direct synchronous calls.

### Loose Coupling

Kafka acts as the backbone of the platform, allowing services to evolve independently.

### Scalability

Consumers and producers can scale horizontally to handle increased telemetry volume.

### Resilience

Failures in downstream processing do not interrupt event ingestion due to Kafka buffering.

### Observability

Metrics, traces, and logs provide insight into system performance and operational health.

---

## MVP Scope

The initial version of PulseStream focuses on a minimal but complete pipeline:

- telemetry ingestion API
- Kafka-based event streaming
- telemetry processing and anomaly detection
- PostgreSQL persistence
- dead-letter routing and operator-triggered replay
- observability through actuator, Prometheus and OpenTelemetry
- Kubernetes deployment with horizontal autoscaling

The MVP scope is met. Remaining platform gaps are tracked as Phase 7 work and listed in full in [PROJECT_STATE.md](../../PROJECT_STATE.md#known-gaps-and-limitations); the largest are:

- anomaly persistence from application code (#267)
- query API for telemetry analytics (#266)
- versioned schema migrations and event contracts (#265, #268)
- authentication on ingestion and encryption on Kafka (#273, #275)
- simulated IoT devices

Future iterations may expand into advanced analytics, device management, and large-scale telemetry simulations.

---

## Future Extensions

Potential improvements include:

- time-series optimized storage
- advanced anomaly detection algorithms
- device fleet management
- multi-tenant telemetry isolation
- large-scale device simulation
- machine learning for anomaly detection

---

## Conclusion

PulseStream demonstrates how cloud-native systems can process high-volume IoT telemetry streams in real time while maintaining scalability, resilience, and observability.

The platform serves as a practical implementation of distributed streaming architectures used in modern telemetry processing systems.
