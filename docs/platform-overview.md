# PulseStream Platform Overview

PulseStream is a cloud-native event processing platform designed to ingest, process, and analyze IoT telemetry data at scale.

The platform currently enables real-time ingestion of telemetry events, Kafka-based processing, anomaly event publishing, persistence of normal processed telemetry records, dead-letter routing of failures, and bounded operator-triggered replay. It is instrumented with OpenTelemetry and deploys to both Docker Compose and Kubernetes. Query APIs and anomaly persistence are planned follow-up work.

The system is designed using an event-driven architecture built around Apache Kafka.

> [`PROJECT_STATE.md`](../PROJECT_STATE.md) is the authoritative record of what is built, validated, and outstanding. The status words used here — **Planned**, **Implemented**, **Validated** — are defined [there](../PROJECT_STATE.md#how-to-read-status-in-this-repository).

---

## Core Capabilities

PulseStream provides the following capabilities:

*   Scalable telemetry ingestion — implemented
*   Event stream processing — implemented
*   Anomaly detection pipelines — implemented; anomalies are published, not persisted
*   Durable processed telemetry storage — implemented for normal readings
*   Dead-letter routing and selective replay — implemented, validated under Docker Compose
*   Metrics, health endpoints, and distributed tracing — implemented
*   Kubernetes deployment with autoscaling and network isolation — implemented
*   Real-time querying APIs — planned

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
*   Routing publish failures to the dead-letter topic with error metadata

This service acts as the **entry point of the platform**. It is unauthenticated and unencrypted today ([#273](https://github.com/ME-Massine/pulsestream/issues/273)).

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

*   telemetry-processor — implemented
*   alerting or aggregation consumers — planned

These services read from Kafka topics and produce new events downstream. The telemetry processor also routes its own failures to `telemetry.events.dlq` and hosts the bounded replay listener that reads that topic back.

---

### Storage Layer

Normal processed telemetry records are stored in PostgreSQL. The schema script defines an anomalies table, but application code publishes anomaly events to Kafka and does not persist them ([#267](https://github.com/ME-Massine/pulsestream/issues/267)).

The database supports:

*   Planned query APIs
*   Planned dashboards
*   Planned anomaly analysis
*   Device history

The schema is applied by an initialisation script rather than by versioned migrations ([#265](https://github.com/ME-Massine/pulsestream/issues/265)), and no PostgreSQL manifest is committed for Kubernetes.

Redis is provisioned in the local stack as a future caching layer. No application code uses it.

---

### Query Service

**Status:** Scaffold. `services/query-service` is a Spring Boot application with actuator and Prometheus endpoints, a production Dockerfile, and Kubernetes manifests. It has no controllers, no data access, and no query endpoints, and it emits no traces.

The planned query service exposes APIs to retrieve processed telemetry data.

**Planned responsibilities:**

*   Querying PostgreSQL
*   Aggregating device telemetry
*   Exposing REST endpoints

Tracked by [#266](https://github.com/ME-Massine/pulsestream/issues/266) and [#267](https://github.com/ME-Massine/pulsestream/issues/267).

---

### Observability Stack

The local platform includes a full observability stack:

*   Prometheus scraping the services' actuator metrics endpoints
*   Grafana with a provisioned Prometheus datasource
*   OpenTelemetry instrumentation in `ingestion-service` and `telemetry-processor`, exporting OTLP over `http/protobuf`
*   Jaeger as the trace backend
*   Centralized logging — planned

In Kubernetes only part of this exists: an OpenTelemetry Collector receives spans from the two instrumented services, but traces terminate in its `debug` exporter, and Prometheus and Grafana are not deployed there yet (#154–#159).

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

### Production Deployment

Production deployments target **Kubernetes**. Manifests for all three services, Kafka via the Strimzi operator, service discovery, external ingestion, network isolation, autoscaling, and the OpenTelemetry Collector are committed under `infrastructure/kubernetes/` and have been applied against a live cluster. A PostgreSQL Service reachable at `postgres:5432` must be provisioned out of band.

Kubernetes provides:

*   Horizontal scaling
*   Service orchestration
*   Rolling deployments
*   Resilience and recovery

---

## Architecture Documentation

Detailed architecture documentation is available in:

```bash
PROJECT_STATE.md
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
3.  Core Event Pipeline — complete
4.  Observability — complete under Docker Compose
5.  Reliability and Resilience — complete
6.  Kubernetes Deployment — in progress
7.  Production Readiness and Platform Hardening — in progress, current phase

The development roadmap is documented in:

```bash
docs/roadmap.md
```
