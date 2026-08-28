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
- telemetry-processor, when republishing operator-selected dead-letter records during replay

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
- none today. query-service is a scaffold ([#266](https://github.com/ME-Massine/pulsestream/issues/266)) and no other downstream consumer exists

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
- none today. Anomaly persistence and querying are planned ([#267](https://github.com/ME-Massine/pulsestream/issues/267)); alerting consumers are planned ([#276](https://github.com/ME-Massine/pulsestream/issues/276))

**Configuration**
- partitions: 3
- replication-factor: 3
- retention: 7 days

---

## telemetry.events.dlq

**Description**  
Dead-letter queue for failed events. Each record is a `DeadLetterEvent` wrapper: the nested original event plus failure metadata, including the `sourceService` that routed it.

**Producers**
- ingestion-service — when publishing an accepted event to `telemetry.events.raw` fails
- telemetry-processor — on the first processing failure; no retry policy is configured on the listener container

**Consumers**
- telemetry-processor's `dlq-replay-listener`, which is registered with `autoStartup=false` and runs only while an operator has started a replay. See [event-replay-strategy.md](./event-replay-strategy.md)
- manual inspection

**Configuration**
- partitions: 1
- replication-factor: 3
- retention: 7 days
