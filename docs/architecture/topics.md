# Kafka Topics

## Overview

This document defines the Kafka topics used in the platform.

---

## telemetry.events.raw

**Description**  
Raw telemetry data ingested from devices.

**Producers**
- ingestion-service
- device-simulator

**Consumers**
- analytics-processor

**Configuration**
- partitions: 3
- replication-factor: 1
- retention: 24h

---

## telemetry.events.processed

**Description**  
Processed telemetry data after enrichment and anomaly detection.

**Producers**
- analytics-processor

**Consumers**
- query-service

**Configuration**
- partitions: 3
- replication-factor: 1
- retention: 7 days

---

## telemetry.events.dlq

**Description**  
Dead-letter queue for failed events.

**Producers**
- analytics-processor

**Consumers**
- monitoring / manual inspection

**Configuration**
- partitions: 1
- replication-factor: 1
- retention: 7 days