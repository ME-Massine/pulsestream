# PulseStream Platform Overview

PulseStream is a cloud-native event processing platform designed to ingest, process, and analyze IoT telemetry data at scale.

The platform ingests telemetry over HTTP, transports it through Kafka, normalizes it and detects anomalies, persists normal processed telemetry to PostgreSQL, routes failures to a dead-letter queue with operator-triggered replay, emits metrics and distributed traces, and deploys to Kubernetes with horizontal autoscaling. Query APIs and anomaly persistence are planned follow-up work (#266, #267).

[PROJECT_STATE.md](../PROJECT_STATE.md) is the authoritative record of platform status; where this overview disagrees with it, that file is correct.

The system is designed using an event-driven architecture built around Apache Kafka.

---

## Core Capabilities

PulseStream provides the following capabilities:

*   Scalable telemetry ingestion
*   Event stream processing
*   Anomaly detection pipelines
*   Durable processed telemetry storage
*   Dead-letter routing and bounded, operator-triggered event replay
*   Metrics, health endpoints and distributed tracing
*   Kubernetes deployment with horizontal autoscaling
*   Planned real-time querying APIs (#266)

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
*   planned alerting or aggregation consumers (#276); nothing consumes the processed or anomalies topics today

These services read from Kafka topics and produce new events downstream.

---

### Storage Layer

Normal processed telemetry records are stored in PostgreSQL, upserted by `event_id`. The schema script defines an `anomalies` table, but application code publishes anomaly events to Kafka and does not persist them (#267).

The schema is applied by an init script; there is no versioned migration tool yet (#265), and no PostgreSQL is provisioned inside Kubernetes.

The database supports:

*   Planned query APIs
*   Planned dashboards
*   Planned anomaly analysis
*   Device history

Redis is provisioned in the local stack as a future caching layer. No service uses it today.

---

### Query Service

**Status:** Scaffold only. `services/query-service` runs and exposes actuator endpoints, and has container and Kubernetes manifests, but has no REST endpoints and no database access (#266).

The responsibilities below describe the intended service.

**Responsibilities:**

*   Querying PostgreSQL
*   Aggregating device telemetry
*   Exposing REST endpoints

---

### Observability Stack

Observability is implemented in both environments:

*   Prometheus for metrics, locally and in cluster, and as the metric source for custom autoscaling
*   Grafana dashboards for service health and ingestion metrics locally; a base deployment in cluster without a datasource yet (#156)
*   OpenTelemetry instrumentation in the services, with an in-cluster Collector; traces stop at the HTTP boundary until the Kafka producer path is instrumented (#294)
*   Jaeger as the local trace backend; no in-cluster tracing backend yet (#158)
*   Centralized logging as planned follow-up work

`telemetry-processor` is deliberately not scraped: its actuator surface, which includes the state-changing `dlqreplay` endpoint, is bound to loopback on a separate management port.

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

Production deployments target **Kubernetes**, and the manifests exist in `infrastructure/kubernetes/`: Deployments, Services and ConfigMaps for all three services, Kafka in KRaft mode via the Strimzi operator, ClusterIP service discovery with a NodePort for external ingestion, NetworkPolicies, and HorizontalPodAutoscalers on CPU and on a Prometheus custom metric.

Kubernetes provides:

*   Horizontal scaling
*   Service orchestration
*   Rolling deployments
*   Resilience and recovery

A PostgreSQL instance is a prerequisite: the platform does not provision one in cluster.

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
3.  Core Event Pipeline — complete
4.  Observability — complete for the local platform
5.  Reliability and Resilience — complete
6.  Kubernetes Deployment — in progress
7.  Production Readiness and Platform Hardening — current phase

The development roadmap is documented in:

```bash
docs/roadmap.md
```
