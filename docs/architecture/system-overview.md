# PulseStream — System Overview

## Introduction

PulseStream is a cloud-native distributed platform designed to ingest, process, and analyze IoT telemetry events in real time. The platform focuses on scalable event processing and anomaly detection using modern cloud-native architecture patterns.

IoT devices continuously generate telemetry data such as temperature, humidity, vibration, and other operational metrics. Traditional systems often struggle to process these streams at scale while maintaining reliability and observability.

PulseStream addresses this challenge by using an event-driven architecture built around distributed streaming and asynchronous processing.

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

Detected anomalies are emitted as dedicated Kafka events. The database schema includes an anomalies table, but application-level anomaly persistence is not implemented yet.

### Data Persistence

Normal processed telemetry readings are stored in PostgreSQL for historical querying and analytics.

### Failure Handling and Replay

Failures on both the ingestion and the processing hop are routed to `telemetry.events.dlq` with error metadata rather than being dropped. An operator can trigger a bounded, selective replay that reads the dead-letter topic and republishes only chosen `eventId`s back to `telemetry.events.raw`. Both behaviours are implemented and validated under Docker Compose. See [`event-replay-strategy.md`](event-replay-strategy.md).

### Query APIs

Dedicated query APIs are planned. `services/query-service` exists as a **scaffold** — it deploys and reports healthy, but has no controllers, no data access, and no query endpoints ([#266](https://github.com/ME-Massine/pulsestream/issues/266)).

### Observability

All three services expose actuator health and Prometheus metrics endpoints, with Kubernetes probe groups mirrored to `/livez` and `/readyz`.

**Distributed tracing is implemented.** `ingestion-service` and `telemetry-processor` carry the OpenTelemetry Spring Boot starter, propagate W3C `tracecontext` and `baggage`, export OTLP over `http/protobuf`, and emit `trace_id` and `span_id` in their logs. Under Docker Compose they export to Jaeger; on Kubernetes they export to an OpenTelemetry Collector, where traces currently terminate in a `debug` exporter because no trace backend is deployed in the cluster yet. `query-service` is not instrumented.

### Deployment

The platform deploys to Kubernetes: Deployments for all three services with probes and resource bounds, Kafka via the Strimzi operator in KRaft mode with persistent storage, ClusterIP service discovery, NodePort external ingestion, default-deny NetworkPolicies, and CPU-based horizontal autoscaling. No PostgreSQL manifest is committed; that Service is provisioned out of band.

---

## High-Level Architecture

The platform is composed of several distributed components that communicate through an event streaming backbone.

### Main Components

| Component | Description | Status |
|---|---|---|
| Ingestion Service | Accepts telemetry events from devices, publishes them to Kafka, and dead-letters publish failures | Implemented |
| Kafka Cluster | Central streaming backbone responsible for event transport and buffering | Implemented under Docker Compose and on Kubernetes (Strimzi, KRaft) |
| Telemetry Processor | Consumes telemetry streams, normalizes, detects anomalies, persists processed telemetry, dead-letters failures, and performs bounded replay | Implemented |
| Query Service | API for processed telemetry and anomaly data | Scaffold — no query endpoints |
| PostgreSQL | Stores normal processed telemetry; the anomalies table exists in the schema script but is unused | Implemented for the write path |
| Observability Stack | Prometheus, Grafana, OpenTelemetry and Jaeger under Docker Compose; an OpenTelemetry Collector on Kubernetes | Metrics and tracing implemented locally; the in-cluster stack is partial |
| Device Simulator | Generator for synthetic telemetry | Planned — no implementation exists |

---

## Event Flow

The typical lifecycle of a telemetry event follows this sequence:

```text
IoT Device
↓
Ingestion Service ──(publish failure)──→ telemetry.events.dlq
↓
Kafka Topic: telemetry.events.raw ←──(selective operator replay)──┐
↓                                                                 │
Telemetry Processor                                               │
├─ normal reading     → PostgreSQL + telemetry.events.processed    │
├─ anomalous reading  → telemetry.events.anomalies                 │
└─ processing failure → telemetry.events.dlq ─────────────────────┘

Planned:
PostgreSQL → Query Service → Dashboard / API Clients
```

During processing, anomaly detection logic publishes events to a dedicated Kafka topic for downstream consumers. Neither `telemetry.events.processed` nor `telemetry.events.anomalies` has a committed consumer today.

---

## Technology Stack

PulseStream uses the following core technologies:

| Technology | Purpose |
|-----------|--------|
| Spring Boot | Microservice framework |
| Apache Kafka | Event streaming platform |
| PostgreSQL | Persistent storage for processed data |
| Redis | Optional caching layer |
| Docker | Containerization of the services and the local development stack |
| Kubernetes | Deployment platform. Service, Kafka, networking, autoscaling and collector manifests are committed and applied |
| Prometheus | Metrics collection in the local stack; not yet deployed in the cluster |
| Grafana | Observability dashboards in the local stack; not yet deployed in the cluster |
| OpenTelemetry | Distributed tracing in the ingestion and processing services |
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
- PostgreSQL persistence of normal processed telemetry
- dead-letter routing and bounded operator replay
- observability through actuator, Prometheus, and OpenTelemetry tracing
- deployment to Kubernetes

Current gaps include:

- anomaly persistence from application code ([#267](https://github.com/ME-Massine/pulsestream/issues/267))
- query API for telemetry analytics ([#266](https://github.com/ME-Massine/pulsestream/issues/266))
- versioned schema migrations ([#265](https://github.com/ME-Massine/pulsestream/issues/265)) and versioned event contracts ([#268](https://github.com/ME-Massine/pulsestream/issues/268))
- authentication and encryption on ingestion ([#273](https://github.com/ME-Massine/pulsestream/issues/273)) and on Kafka client traffic ([#275](https://github.com/ME-Massine/pulsestream/issues/275))
- an in-cluster metrics, dashboard, and tracing stack (#154–#159)
- simulated IoT devices

[`PROJECT_STATE.md`](../../PROJECT_STATE.md) carries the authoritative and complete gap list.

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
