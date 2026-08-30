# Kafka Topics

## Overview

This document defines the Kafka topics used in the platform.

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
- telemetry-processor, when republishing selected dead-letter records during a replay run
- device-simulator (planned; no simulator exists in this repository)

**Consumers**
- telemetry-processor

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
- none today
- query-service (planned, #266)
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
- none today; anomalies are published but neither persisted nor consumed
- anomaly persistence and querying (planned, #267)
- alerting consumers (planned, #276)

**Configuration**
- partitions: 3
- replication-factor: 3
- retention: 7 days

---

## telemetry.events.dlq

**Description**  
Dead-letter queue for failed events. Each record is a `DeadLetterEvent` wrapper: the original event, error metadata, and the `sourceService` that dead-lettered it.

**Producers**
- ingestion-service — when publishing an accepted event to `telemetry.events.raw` fails
- telemetry-processor — when processing a raw event throws, on first failure

**Consumers**
- telemetry-processor `dlq-replay-listener`, under consumer group `telemetry-processor-dlq-replay`. It is registered with `autoStartup=false` and runs only while an operator-triggered replay is in progress; see [event-replay-strategy.md](./event-replay-strategy.md).
- monitoring / manual inspection

**Configuration**
- partitions: 1
- replication-factor: 3
- retention: 7 days
