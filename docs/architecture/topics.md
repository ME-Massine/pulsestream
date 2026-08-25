# Kafka Topics

## Overview

This document defines the Kafka topics used in the platform.

## Naming Convention

Topics follow: `<domain>.<entity>.<stage>`

- `domain` — bounded context (e.g. `telemetry`)
- `entity` — event/data kind (e.g. `events`)
- `stage` — lifecycle stage: `raw`, `processed`, `anomalies`, `dlq`

Dead-letter topics use the `dlq` stage suffix on the domain/entity they guard, e.g. `telemetry.events.dlq` holds failed/malformed messages from the `telemetry.events.*` pipeline. This keeps DLQ topics discoverable next to the topics they protect rather than in a separate namespace.

All four topics are provisioned and in use. `telemetry.events.raw` and `telemetry.events.dlq` have committed producers *and* consumers; `telemetry.events.processed` and `telemetry.events.anomalies` are produced but have no consumer yet. Status words follow [`PROJECT_STATE.md`](../../PROJECT_STATE.md#how-to-read-status-in-this-repository).

The replication factors below are the Kubernetes deployment values (three brokers, replication factor 3 with `min.insync.replicas=2`), provisioned as `KafkaTopic` resources under `infrastructure/kubernetes/kafka/topics.yaml`. The local Docker Compose stack runs a single broker and provisions the same topics at replication factor 1 (`infrastructure/docker/kafka/init-topics.sh`).

---

## telemetry.events.raw

**Description**  
Raw telemetry data ingested from devices.

**Producers**
- ingestion-service
- telemetry-processor, when replaying selected dead-letter events
- device-simulator (planned)

**Consumers**
- telemetry-processor (group `telemetry-processor`)

**Configuration**
- partitions: 3
- replication-factor: 3
- retention: 24h

---

## telemetry.events.processed

**Description**  
Processed telemetry data after enrichment and anomaly detection.

**Producers**
- telemetry-processor

**Consumers**
- none committed
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
- none committed
- query-service (planned)
- alerting consumers (planned)

**Configuration**
- partitions: 3
- replication-factor: 3
- retention: 7 days

---

## telemetry.events.dlq

**Description**  
Dead-letter queue for failed events. Records wrap the original event with error metadata identifying the source service and the failure.

**Producers**
- ingestion-service, when a publish to `telemetry.events.raw` fails
- telemetry-processor, when processing an event fails

**Consumers**
- telemetry-processor replay listener (group `telemetry-processor-dlq-replay`), started on demand by the `dlqreplay` actuator endpoint and bounded by the per-partition end offsets captured at trigger time
- monitoring / manual inspection

**Configuration**
- partitions: 1
- replication-factor: 3
- retention: 7 days
