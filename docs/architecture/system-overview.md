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

Detected anomalies are emitted as dedicated Kafka events. The database schema includes an anomalies table, but application-level anomaly persistence is not implemented yet ([#267](https://github.com/ME-Massine/pulsestream/issues/267)).

### Data Persistence

Normal processed telemetry readings are stored in PostgreSQL for historical querying and analytics. The write is idempotent on `event_id`, and the raw Kafka record is not acknowledged until the projection is stored.

### Failure Handling and Replay

Events that cannot be published or processed are wrapped with error metadata and routed to `telemetry.events.dlq` by whichever service failed. An operator can selectively republish chosen `eventId`s back to `telemetry.events.raw` through an actuator endpoint on `telemetry-processor`, bound to loopback by default. Replayed events carry replay markers, and their projections replace rather than duplicate the existing row. See [event-replay-strategy.md](./event-replay-strategy.md).

### Query APIs

Planned. `services/query-service` is a scaffold — an application class, configuration, and a context-load test, with no endpoints and no data access ([#266](https://github.com/ME-Massine/pulsestream/issues/266)).

### Observability

The event-path services expose actuator health and Prometheus metrics endpoints, and are instrumented with the OpenTelemetry Spring Boot starter, exporting OTLP over `http/protobuf`. Locally, Prometheus scrapes them, Grafana is provisioned with a datasource and version-controlled dashboards, and traces land in Jaeger. In Kubernetes, traces reach the collector and terminate in its `debug` exporter; no Prometheus, Grafana, or trace backend runs in-cluster yet ([#32](https://github.com/ME-Massine/pulsestream/issues/32)).

### Deployment

The platform deploys to Kubernetes: Deployments for all three services with probes and externalized configuration, Strimzi-managed Kafka in KRaft mode with persistent storage, ClusterIP services plus a NodePort for external ingestion, default-deny NetworkPolicies, and CPU-based horizontal pod autoscaling validated end to end.

---

## High-Level Architecture

The platform is composed of several distributed components that communicate through an event streaming backbone.

### Main Components

| Component | Description |
|----------|-------------|
| Ingestion Service | Accepts telemetry events from devices and publishes them to Kafka |
| Kafka Cluster | Central streaming backbone responsible for event transport and buffering |
| Telemetry Processor | Consumes telemetry streams and performs anomaly detection |
| Query Service | Deployed scaffold. No endpoints or data access yet |
| PostgreSQL | Stores processed telemetry data; anomaly table exists in schema script but is never written |
| Observability Stack | Prometheus, Grafana, and Jaeger locally; an OpenTelemetry Collector in-cluster |
| Device Simulator | Not present in the repository and not scheduled |

---

## Event Flow

The typical lifecycle of a telemetry event follows this sequence:

```text
IoT Device
↓
Ingestion Service ──(publish failure)──> telemetry.events.dlq
↓
Kafka Topic: telemetry.events.raw <──(operator-triggered replay)── telemetry.events.dlq
↓
Telemetry Processor ──(processing failure)──> telemetry.events.dlq
↓
├─ PostgreSQL (normal processed telemetry)
├─ Kafka Topic: telemetry.events.processed
└─ Kafka Topic: telemetry.events.anomalies

planned: PostgreSQL → Query Service → Dashboard / API Clients
```
During processing, anomaly detection logic publishes events to a dedicated Kafka topic. Nothing consumes `telemetry.events.processed` or `telemetry.events.anomalies` today.

---

## Technology Stack

PulseStream uses the following core technologies:

| Technology | Purpose |
|-----------|--------|
| Spring Boot | Microservice framework |
| Apache Kafka | Event streaming platform |
| PostgreSQL | Persistent storage for processed data |
| Redis | Provisioned locally for future caching; no service consumes it |
| Docker | Containerization for local development and published service images |
| Kubernetes | Deployment platform, with manifests for services, Kafka, autoscaling, and network isolation |
| Prometheus | Metrics collection |
| Grafana | Observability dashboards |
| OpenTelemetry | Distributed tracing instrumentation and in-cluster collection |

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
- foundational observability through actuator and Prometheus endpoints

Every item of that MVP scope is implemented, and dead-letter routing with selective replay was added on top of it.

Current gaps include:

- anomaly persistence from application code ([#267](https://github.com/ME-Massine/pulsestream/issues/267))
- query API for telemetry analytics ([#266](https://github.com/ME-Massine/pulsestream/issues/266))
- versioned schema migrations rather than an init script ([#265](https://github.com/ME-Massine/pulsestream/issues/265))
- in-cluster metrics collection and a trace backend ([#32](https://github.com/ME-Massine/pulsestream/issues/32))
- TLS and authentication on external ingestion ([#273](https://github.com/ME-Massine/pulsestream/issues/273))
- simulated IoT devices — not scheduled

The authoritative gap list is in [`PROJECT_STATE.md`](../../PROJECT_STATE.md). Future iterations may expand into advanced analytics, device management, and large-scale telemetry simulations.

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
