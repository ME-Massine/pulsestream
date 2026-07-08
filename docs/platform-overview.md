# PulseStream Platform Overview

PulseStream is a cloud-native event processing platform designed to ingest, process, and analyze IoT telemetry data at scale.

The platform currently enables real-time ingestion of telemetry events, Kafka-based processing, anomaly event publishing, and persistence of normal processed telemetry records. Query APIs and anomaly persistence are planned follow-up work.

The system is designed using an event-driven architecture built around Apache Kafka.

---

## Core Capabilities

PulseStream provides the following capabilities:

*   Scalable telemetry ingestion
*   Event stream processing
*   Anomaly detection pipelines
*   Durable processed telemetry storage
*   Planned real-time querying APIs
*   Foundational observability and monitoring

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

**Status:** Planned. There is no query service module in the current checkout.

The query service exposes APIs to retrieve processed telemetry data.

**Responsibilities:**

*   Querying PostgreSQL
*   Aggregating device telemetry
*   Exposing REST endpoints

---

### Observability Stack

The local platform includes a foundational observability stack:

*   Prometheus for metrics
*   Grafana for future dashboards
*   OpenTelemetry for planned distributed tracing
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

Spring Boot platform services are run from their service directories on the host during local development.

---

### Production Deployment

Production deployments are planned to target **Kubernetes**.

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

The platform is developed in structured phases.

1.  System Architecture
2.  Local Development Platform
3.  Core Event Pipeline
4.  Observability
5.  Reliability and Resilience
6.  Kubernetes Deployment

The development roadmap is documented in:

```bash
docs/roadmap.md
```
