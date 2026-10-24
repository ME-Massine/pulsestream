# PulseStream Platform Overview

PulseStream is a cloud-native event processing platform designed to ingest, process, and analyze IoT telemetry data at scale.

The platform enables real-time ingestion of telemetry events, Kafka-based processing, anomaly event publishing, persistence and querying of processed telemetry and anomalies, dead-letter routing with event replay, distributed tracing, and a Prometheus/Grafana observability stack. Kubernetes manifests are committed for the application services, Kafka, and observability components; PostgreSQL must currently be supplied separately. The [processed telemetry](api/processed-telemetry.md) and [anomaly](api/anomalies.md) APIs require the pending Phase 7 authenticated tenant integration. Cross-classification replay consistency remains planned in #271.

The system is designed using an event-driven architecture built around Apache Kafka. The authoritative platform status is maintained in [PROJECT_STATE.md](../PROJECT_STATE.md).

---

## Core Capabilities

PulseStream provides the following capabilities:

*   Scalable telemetry ingestion
*   Event stream processing
*   Anomaly detection pipelines
*   Durable processed telemetry storage
*   Dead-letter routing and event replay
*   Distributed tracing, metrics, and dashboards
*   Processed telemetry queries with tenant, device and time scoping (#266)

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

These services read from Kafka topics and produce new events downstream.

---

### Storage Layer

Processed telemetry and anomaly projections are stored in PostgreSQL before Kafka publication. Processor-owned Flyway migrations define both tables. Anomalies preserve detection reasons and metadata, deduplicate by event ID and update same-tenant explicit replays atomically (#267).

The database supports:

*   Future query APIs
*   Future dashboards
*   Future anomaly analysis
*   Device history

Redis may be used as a caching layer for frequently requested data.

---

### Query Service

**Status:** Processed telemetry API implemented (#266); authenticated tenant integration and live validation pending.

The query service exposes a tenant-scoped API for retrieving processed telemetry data.

**Responsibilities:**

*   Querying PostgreSQL
*   Filtering by device/time with bounded pagination; aggregations remain planned
*   Exposing REST endpoints

---

### Observability Stack

The platform includes an observability stack:

*   Prometheus for metrics
*   Grafana with version-controlled dashboards (provisioned locally and in-cluster)
*   OpenTelemetry instrumentation exporting OTLP traces to Jaeger (local) or an OpenTelemetry Collector (Kubernetes)
*   Centralized logging as planned follow-up work

---

## Deployment Model

PulseStream follows a two-stage deployment strategy.

### Local Development

Local environments run using **Docker Compose**.

This provides:

*   Kafka
*   PostgreSQL
*   Redis
*   Prometheus
*   Grafana
*   Jaeger

Spring Boot platform services are run from their service directories on the host during local development.

---

### Production Deployment

Cluster deployment targets **Kubernetes**. Manifests for the platform services, Kafka (via the Strimzi operator), observability, autoscaling, and network policies are committed under `infrastructure/kubernetes/`; PostgreSQL must currently be provisioned separately. Full-platform end-to-end validation against a live target cluster is the outstanding Phase 6 exit gate that must be met before Phase 7 begins.

Kubernetes provides:

*   Horizontal scaling
*   Service orchestration
*   Rolling deployments
*   Resilience and recovery

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

The platform is developed in structured phases. Phases 1 through 5 are complete. Phase 6 Kubernetes deployment implementation is complete, but its live target-cluster validation remains pending; Phase 7 begins only after that gate is met.

1.  System Architecture
2.  Local Development Platform
3.  Core Event Pipeline
4.  Observability
5.  Reliability and Resilience
6.  Kubernetes Deployment
7.  Production Readiness and Platform Hardening

The development roadmap is documented in:

```bash
docs/roadmap.md
```
