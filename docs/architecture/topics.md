# Kafka Topics

## Overview

This document defines the Kafka topics used in the platform.

## Naming Convention

Topics follow: `<domain>.<entity>.<stage>`

- `domain` — bounded context (e.g. `telemetry`)
- `entity` — event/data kind (e.g. `events`)
- `stage` — lifecycle stage: `raw`, `processed`, `anomalies`, `dlq`

Dead-letter topics use the `dlq` stage suffix on the domain/entity they guard, e.g. `telemetry.events.dlq` holds failed/malformed messages from the `telemetry.events.*` pipeline. This keeps DLQ topics discoverable next to the topics they protect rather than in a separate namespace.

---

## telemetry.events.raw

**Description**  
Raw telemetry data ingested from devices.

**Producers**
- ingestion-service
- device-simulator (planned)

**Consumers**
- telemetry-processor

**Configuration**
- partitions: 3
- replication-factor: 1
- retention: 24h

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
- replication-factor: 1
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
- replication-factor: 1
- retention: 7 days

---

## telemetry.events.dlq

**Description**  
Dead-letter queue for failed events.

**Producers**
- telemetry-processor

**Consumers**
- monitoring / manual inspection

**Configuration**
- partitions: 1
- replication-factor: 1
- retention: 7 days
