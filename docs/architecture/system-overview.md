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

### Query APIs

Dedicated query APIs are planned (Phase 7). A deployable `services/query-service` scaffold exists, but its REST endpoints and data access are not yet implemented.

### Observability

The services expose health and Prometheus metrics endpoints, ship version-controlled Grafana dashboards, and are instrumented with OpenTelemetry, exporting OTLP traces to Jaeger (local) or an OpenTelemetry Collector (Kubernetes).

---

## High-Level Architecture

The platform is composed of several distributed components that communicate through an event streaming backbone.

### Main Components

| Component | Description |
|----------|-------------|
| Ingestion Service | Accepts telemetry events from devices and publishes them to Kafka |
| Kafka Cluster | Central streaming backbone responsible for event transport and buffering |
| Telemetry Processor | Consumes telemetry streams, performs anomaly detection, and handles dead-letter routing and replay |
| Query Service | Deployable scaffold; query APIs for processed telemetry and anomaly data are Phase 7 work |
| PostgreSQL | Stores processed telemetry data; anomaly table exists in schema script (application-level anomaly persistence is Phase 7 work) |
| Observability Stack | Prometheus, Grafana dashboards, and OpenTelemetry tracing (Jaeger locally, OpenTelemetry Collector in Kubernetes) |
| Device Simulator | Planned generator for synthetic telemetry |

---

## Event Flow

The typical lifecycle of a telemetry event follows this sequence:

```text
IoT Device / Simulator
↓
Ingestion Service
↓
Kafka Topic: telemetry.events.raw
↓
Telemetry Processor
↓
Kafka Topics:
- telemetry.events.processed
- telemetry.events.anomalies
↓
PostgreSQL
↓
Query Service (scaffold)
↓
Dashboard / API Clients

```
During processing, anomaly detection logic may publish events to dedicated Kafka topics for downstream consumers. Events that fail processing are routed to `telemetry.events.dlq` and can be replayed back into the pipeline.

---

## Technology Stack

PulseStream uses the following core technologies:

| Technology | Purpose |
|-----------|--------|
| Spring Boot | Microservice framework |
| Apache Kafka | Event streaming platform |
| PostgreSQL | Persistent storage for processed data |
| Redis | Optional caching layer |
| Docker | Containerization for local development |
| Kubernetes | Cluster deployment target; manifests committed under `infrastructure/kubernetes/` |
| Prometheus | Metrics collection |
| Grafana | Observability dashboards |
| OpenTelemetry | Distributed tracing instrumentation (OTLP export) |

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

Current gaps (addressed in Phase 7) include:

- anomaly persistence from application code
- query API for telemetry analytics (the `query-service` is a scaffold)
- simulated IoT devices

Dead-letter routing and event replay are implemented. Future iterations may expand into advanced analytics, device management, and large-scale telemetry simulations.

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
