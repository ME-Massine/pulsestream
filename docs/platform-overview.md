# PulseStream Platform Overview

PulseStream is a cloud-native event processing platform designed to ingest, process, and analyze IoT telemetry data at scale.

The platform enables real-time ingestion of telemetry events, Kafka-based processing, anomaly event publishing, persistence of normal processed telemetry records, dead-letter routing with event replay, distributed tracing, and a Prometheus/Grafana observability stack. Kubernetes manifests are committed for all workloads. Query APIs and application-level anomaly persistence are the primary remaining gaps, addressed in Phase 7.

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
*   Planned real-time querying APIs

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

Normal processed telemetry records are stored in PostgreSQL. The schema script defines an anomalies table, but the current application code publishes anomaly events to Kafka and does not persist them yet.

The database supports:

*   Future query APIs
*   Future dashboards
*   Future anomaly analysis
*   Device history

Redis may be used as a caching layer for frequently requested data.

---

### Query Service

**Status:** Scaffold. A deployable `services/query-service` module and its Kubernetes manifests exist, but the REST query endpoints and data access are Phase 7 work.

The query service exposes APIs to retrieve processed telemetry data.

**Responsibilities:**

*   Querying PostgreSQL
*   Aggregating device telemetry
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

Cluster deployment targets **Kubernetes**. Manifests for all workloads — the platform services, Kafka (via the Strimzi operator), observability, autoscaling, and network policies — are committed under `infrastructure/kubernetes/`. End-to-end validation against a live target cluster is completed as part of Phase 7.

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

The platform is developed in structured phases. Phases 1 through 6 are complete; Phase 7 is in progress.

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
