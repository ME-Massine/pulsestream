# PulseStream Platform Overview

PulseStream is a cloud-native event processing platform designed to ingest, process, and analyze IoT telemetry data at scale.

The platform ingests telemetry events over HTTP, transports and processes them through Kafka, detects anomalies, persists processed telemetry to PostgreSQL, routes failures to a dead-letter queue, and replays them on operator command. It is instrumented for metrics and distributed tracing, and deploys to Kubernetes. Query APIs and anomaly persistence are the main remaining gaps.

The system is designed using an event-driven architecture built around Apache Kafka.

[`PROJECT_STATE.md`](../PROJECT_STATE.md) is the authoritative record of what is implemented, validated, and planned; this document is an introduction, not a status report.

---

## Core Capabilities

PulseStream provides the following capabilities:

*   Scalable telemetry ingestion
*   Event stream processing
*   Anomaly detection pipelines
*   Durable processed telemetry storage
*   Dead-letter routing and selective, operator-triggered event replay
*   Metrics, distributed tracing, and health monitoring
*   Kubernetes deployment with autoscaling and network isolation
*   Real-time querying APIs — planned ([#266](https://github.com/ME-Massine/pulsestream/issues/266))

---

## High-Level Architecture

The platform consists of several core components.

### Event Producers

Devices or gateways that send telemetry events to the platform.

**Examples:**

*   IoT sensors
*   Industrial gateways
*   Edge devices

These producers send telemetry data through the ingestion API.

---

### Ingestion Service

The ingestion service is responsible for:

*   Receiving telemetry events
*   Validating the event schema
*   Enriching metadata if required
*   Publishing events to Kafka

This service acts as the **entry point of the platform**.

---

### Event Streaming Layer (Kafka)

Apache Kafka acts as the central event streaming backbone.

Kafka provides:

*   Durable event storage
*   Scalable event distribution
*   Consumer isolation through consumer groups
*   Event replay capabilities

Core topics include:

```text
telemetry.events.raw
telemetry.events.processed
telemetry.events.anomalies
telemetry.events.dlq
```

---

### Processing Services

Processing services consume telemetry streams and perform transformations.

**Example processors:**

*   telemetry-processor
*   planned alerting or aggregation consumers

These services read from Kafka topics and produce new events downstream. A processing failure is wrapped with error metadata and routed to `telemetry.events.dlq` on the first attempt — there is no retry policy — and is recovered by operator-triggered replay rather than by an automatic retry loop.

---

### Storage Layer

Normal processed telemetry records are stored in PostgreSQL. The write is idempotent on `event_id`, so an at-least-once redelivery is a no-op and a replay replaces the existing projection. The schema script defines an anomalies table, but the current application code publishes anomaly events to Kafka and does not persist them yet ([#267](https://github.com/ME-Massine/pulsestream/issues/267)).

The database supports:

*   Future query APIs
*   Future dashboards
*   Future anomaly analysis
*   Device history

Redis may be used as a caching layer for frequently requested data.

---

### Query Service

**Status:** Scaffold. `services/query-service` exists, builds, is containerized, and is deployed to Kubernetes, but has no REST endpoints and no data access ([#266](https://github.com/ME-Massine/pulsestream/issues/266)).

The query service will expose APIs to retrieve processed telemetry data.

**Responsibilities:**

*   Querying PostgreSQL
*   Aggregating device telemetry
*   Exposing REST endpoints

---

### Observability Stack

The local platform includes an observability stack:

*   Prometheus scraping the services' actuator metrics endpoints
*   Grafana, provisioned with a Prometheus datasource and version-controlled dashboards from `observability/grafana/dashboards/`
*   OpenTelemetry instrumentation in both event-path services, exporting OTLP traces to Jaeger
*   Centralized logging as planned follow-up work

In Kubernetes, an OpenTelemetry Collector receives those traces, but no Prometheus, Grafana, or trace backend runs in-cluster yet ([#32](https://github.com/ME-Massine/pulsestream/issues/32)).

---

## Deployment Model

PulseStream follows a two-stage deployment strategy.

### Local Development

Local environments run using **Docker Compose**.

This provides:

*   Kafka and Zookeeper
*   PostgreSQL
*   Redis
*   Prometheus
*   Grafana
*   Jaeger

Spring Boot platform services are run from their service directories on the host during local development.

---

### Kubernetes Deployment

Manifests under `infrastructure/kubernetes/` deploy all three services with probes and externalized configuration, Strimzi-managed Kafka in KRaft mode with persistent storage, internal ClusterIP services plus a NodePort for external ingestion, default-deny NetworkPolicies, CPU-based horizontal pod autoscaling, and an OpenTelemetry Collector.

Two things the manifests do not provide: PostgreSQL, which `telemetry-processor` expects as a `postgres:5432` Service in its namespace, and TLS or authentication in front of external ingestion ([#273](https://github.com/ME-Massine/pulsestream/issues/273)).

---

## Architecture Documentation

Detailed architecture documentation is available in:

```bash
docs/architecture/
docs/diagrams/
docs/decisions/
```

These include:

*   System architecture diagrams
*   Event schema definitions
*   Service boundaries
*   Architecture decision records (ADRs)

---

## Engineering Phases

The platform is developed in structured phases.

1.  System Architecture — complete
2.  Local Development Platform — complete
3.  Core Event Pipeline — complete for the write path
4.  Observability — complete for the local stack
5.  Reliability and Resilience — complete
6.  Kubernetes Deployment — complete except the in-cluster observability stack
7.  Production Readiness and Platform Hardening — in progress

The development roadmap is documented in:

```bash
docs/roadmap.md
```
