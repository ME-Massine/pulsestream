# Kafka Topics

## Overview

This document defines the Kafka topics used in the platform.

Each topic's JSON value has an authoritative versioned schema under
[contracts/schemas](../../contracts/schemas). See [event schemas](event-schema.md)
for the topic-to-schema mapping and [contract policy](../../contracts/README.md)
for version compatibility and shared fixtures.

## Naming Convention

Topics follow: `<domain>.<entity>.<stage>`

- `domain` — bounded context (e.g. `telemetry`)
- `entity` — event/data kind (e.g. `events`)
- `stage` — lifecycle stage: `raw`, `processed`, `anomalies`, `dlq`

Dead-letter topics use the `dlq` stage suffix on the domain/entity they guard, e.g. `telemetry.events.dlq` holds failed/malformed messages from the `telemetry.events.*` pipeline. This keeps DLQ topics discoverable next to the topics they protect rather than in a separate namespace.

The replication factors below are the Kubernetes deployment values (three brokers, replication factor 3 with `min.insync.replicas=2`), provisioned as `KafkaTopic` resources under `infrastructure/kubernetes/kafka/topics.yaml`. The local Docker Compose stack runs a single broker and provisions the same topics at replication factor 1 (`infrastructure/docker/kafka/init-topics.sh`).

---

## telemetry.events.raw

**Description**  
Raw telemetry data ingested from devices.

**Producers**
- ingestion-service
- telemetry-processor (DLQ replay)
- device-simulator (planned)

**Consumers**
- telemetry-processor

**Configuration**
- partitions: 3
- replication-factor: 3
- retention: 24h

**Ordering contract (#269)**

Ingestion and replay key raw records by
`v1:base64url(UTF-8(trim(tenantId))):base64url(UTF-8(trim(deviceId)))`, without
padding. Kafka partition offset defines reading order; event ID remains in the
value. External writers must use the same standard keyed partitioner and no
explicit partition override. The partition count stays three. At concurrency
one, three processor replicas are the useful ceiling. See
[anomaly detection](anomaly-detection.md) for durable state, retention, rebalance
recovery and the required paused/drained migration from event-ID keys.

---

## telemetry.events.processed

**Description**  
Processed telemetry data after enrichment and anomaly detection.

**Producers**
- telemetry-processor

**Consumers**
- query-service (planned)
- downstream consumers (planned)

**Configuration**
- partitions: 3
- replication-factor: 3
- retention: 7 days

---

## telemetry.events.anomalies

**Description**  
Detected anomalies from telemetry data.

**Producers**
- telemetry-processor

**Consumers**
- query-service (planned)
- future alerting consumers

**Configuration**
- partitions: 3
- replication-factor: 3
- retention: 7 days

---

## telemetry.events.dlq

**Description**  
Dead-letter queue for failed events.

**Producers**
- ingestion-service
- telemetry-processor

**Consumers**
- telemetry-processor replay listener, started by the management endpoint (bounded, snapshot-based replay)
- monitoring / manual inspection

**Configuration**
- partitions: 1
- replication-factor: 3
- retention: 7 days
