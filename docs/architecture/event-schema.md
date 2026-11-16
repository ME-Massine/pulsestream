# Event Schema Specification

Current processed/anomaly writers emit v2 operation envelopes. UPSERT carries the
result; RETRACT omits payload/detection metadata and removes the obsolete topic
projection. Both include classificationRevision and the resulting classification.
The examples describing v1 below remain historical compatibility contracts. See
[reclassification](replay-reclassification.md) and the authoritative v2 schemas in
contracts/schemas for current producer behavior. Raw and DLQ remain v1.

## Overview

PulseStream transports JSON events through Kafka. The authoritative contracts are
the versioned JSON Schema Draft 2020-12 files below. This document explains their
meaning; [the contract policy](../../contracts/README.md) defines compatibility,
shared fixtures, validation, version mapping and deprecation.

| Topic | Authoritative schema |
| --- | --- |
| `telemetry.events.raw` | [raw v1](../../contracts/schemas/raw/v1.schema.json) |
| `telemetry.events.processed` | [processed v2](../../contracts/schemas/processed/v2.schema.json) (v1 is historical) |
| `telemetry.events.anomalies` | [anomaly v2](../../contracts/schemas/anomaly/v2.schema.json) (v1 is historical) |
| `telemetry.events.dlq` | [shared dead-letter v1](../../contracts/schemas/dead-letter/v1.schema.json) |

---

## Event Envelope

Raw, processed and anomaly events use the telemetry envelope. DLQ values instead
use the shared wrapper described below. Query APIs read PostgreSQL projections.

```json
{
  "eventId": "evt_001",
  "tenantId": "site_nador_01",
  "eventType": "telemetry.reading",
  "timestamp": "2026-03-15T12:00:00Z",
  "source": "device-gateway",
  "version": "1.0",
  "payload": {}
}
```
The envelope separates system metadata from business data.

### Envelope Fields

| Field     | Description                       |
|-----------|-----------------------------------|
| eventId   | Unique identifier for the event   |
| tenantId  | Logical tenant or site identifier |
| eventType | Type of event being emitted       |
| timestamp | Time when the event occurred      |
| source    | Originating system or service     |
| version   | Event schema version              |
| payload   | Domain-specific event data        |

### Event Types

The platform supports several event categories.

#### Telemetry Events

Produced when devices send telemetry readings.

*   `telemetry.reading`

#### Processed Telemetry Events

Produced after the telemetry-processor normalizes or enriches telemetry data.

*   `telemetry.processed`

#### Anomaly Events

Generated when telemetry readings violate anomaly rules.

*   `telemetry.anomaly`

#### Dead Letter Events

Generated when raw publication or event processing fails. These use a wrapper
with `event`, `errorMessage`, `sourceService`, `failedAt` and `version`; they do
not have a top-level `eventType`. Both producers emit the same contract:

```json
{
  "version": "1.0",
  "event": {"eventId": "evt_102", "version": "1.0", "payload": null},
  "errorMessage": "IllegalStateException: processing failed",
  "sourceService": "telemetry-processor",
  "failedAt": "2026-10-24T12:00:00Z"
}
```

The nested event may be invalid telemetry: preserving diagnostic evidence is the
purpose of the DLQ. Historical wrappers without `version` mean v1.0. The complete
producer and consumer examples live in [shared fixtures](../../contracts/fixtures).

### Telemetry Event Example

This event represents a telemetry reading sent by a device.

```json
{
"eventId": "evt_102",
"tenantId": "factory_01",
"eventType": "telemetry.reading",
"timestamp": "2026-03-15T12:05:21Z",
"source": "sensor_gateway",
"version": "1.0",
"payload": {
"deviceId": "sensor_1042",
"deviceType": "temperature-sensor",
"metric": "temperature",
"value": 28.4,
"unit": "C",
"location": "zone-a"
}
}
```

### Telemetry Payload Fields

All six fields are required for new raw ingestion. Historical processed readings
may lack descriptive metadata; anomaly readings may lack any payload field.
Nullability and optionality are specified in the linked schemas.

| Field      | Description                   |
|------------|-------------------------------|
| deviceId   | Unique device identifier      |
| deviceType | Type of sensor                |
| metric     | Type of measurement           |
| value      | Sensor reading                |
| unit       | Measurement unit              |
| location   | Logical device location       |

### Anomaly Event Example

When the telemetry-processor detects abnormal behavior, it emits an anomaly event. The event reuses
the standard envelope and telemetry payload, and adds detection metadata (`severity`, `reasons`,
`detectedAt`) at the envelope level so downstream consumers can act on it without re-running
detection.

```json
{
"eventId": "evt_203",
"tenantId": "factory_01",
"eventType": "telemetry.anomaly",
"timestamp": "2026-03-15T12:05:21Z",
"source": "telemetry-processor",
"version": "1.0",
"payload": {
"deviceId": "sensor_1042",
"deviceType": "temperature-sensor",
"metric": "temperature",
"value": 95.0,
"unit": "C",
"location": "zone-a"
},
"severity": "WARNING",
"reasons": ["temperature is above maximum threshold"],
"detectedAt": "2026-03-15T12:05:23Z"
}
```

### Anomaly Event Fields

| Field        | Description                                                                 |
|--------------|-----------------------------------------------------------------------------|
| eventType    | Always `telemetry.anomaly`                                                   |
| source       | Always `telemetry-processor`                                                |
| timestamp    | Original reading timestamp, carried over from the raw event                 |
| payload      | Standard telemetry payload (see fields above)                               |
| severity     | Detection severity: `WARNING` or `CRITICAL`                                 |
| reasons      | List of human-readable explanations for why the reading was flagged         |
| detectedAt   | Timestamp at which the processor detected the anomaly                       |

### Anomaly Types

The platform initially supports the following anomaly types.

#### Threshold Breach

Triggered when a sensor reading exceeds predefined limits.

Implemented rules:

*   `temperature > 80`
*   `temperature < -40`
*   missing `tenantId`, `deviceId`, `metric`, or `value`

#### Sudden Deviation

Triggered when the value changes significantly in a short time interval.

Implemented rule:

*   value change greater than 50% from the previous reading for the same normalized device/metric key

#### Missing Heartbeat

Planned for a future reliability phase. It is documented as an intended anomaly type but is not implemented in the current telemetry processor.

### Kafka Topic Mapping

Events are routed through Kafka topics.

| Topic                        | Purpose                     |
|-----------------------------|-----------------------------|
| `telemetry.events.raw`      | Raw telemetry events        |
| `telemetry.events.processed`| Normalized telemetry events |
| `telemetry.events.anomalies`| Detected anomalies          |
| `telemetry.events.dlq`      | Failed events               |

### Event Versioning

The existing wire version is `MAJOR.MINOR`. Topic plus major selects the schema;
v1 schemas accept `1.x`. Current processed and anomaly producers declare `2.0`
and publish v2 UPSERT/RETRACT operations; v1 is a historical compatibility contract.
Current DLQ producers declare `1.0`. Versions are independent of the input minor
version; replay preserves the raw event version.
Historical DLQ wrappers without a version are implicitly `1.0`.

### Schema Evolution Strategy

CI compares schemas against the PR base or previous push commit. Optional field
additions and annotation edits pass within a major. Existing field/constraint
changes require a new major schema while retaining prior schemas and fixtures.
Java consumers ignore unknown envelope and payload fields. Maven tests validate
the schemas, producer output and consumer fixtures, including both DLQ producers.
See [the evolution and retirement process](../../contracts/README.md#evolution-and-deprecation-process)
and [ADR 0007](../decisions/0007-json-event-contracts.md). No registry deployment or
Avro/Protobuf migration is included.

### Event Validation

Events received by the ingestion service must pass basic validation checks:

*   required envelope fields present
*   valid timestamp format
*   payload structure matches event type

Metric-specific bounds are handled by the telemetry processor anomaly detection rules rather than by the ingestion API.

Invalid HTTP ingestion requests, unsupported raw event types and unsupported
major versions return 400 through Bean Validation. JSON Schema conformance is
enforced in build-time contract tests; a runtime schema validator is not added to
Kafka listeners. Processing failures use the shared DLQ wrapper, which the
processor can selectively replay via its existing management endpoint. Historical
records and replay sources are not rewritten.

## Summary

This schema specification defines the contract between all PulseStream services.

By enforcing a consistent event structure, the platform ensures:

*   interoperability between services
*   reliable event processing
*   safe schema evolution
*   simplified debugging and monitoring

## Replay classification (#271)

Authoritative event classifications and Flyway V6 now reconcile all replay
transitions. Processed/anomaly writers emit v2 UPSERT/RETRACT values on existing
topics; raw/DLQ contracts and published v1 fixtures remain available. Query readers
require V6 and SELECT on `platform.event_classifications`. See [the classification
contract](replay-reclassification.md) for revisions, unresolved legacy conflicts, bounded
replay, consumer migration and the coordinated paused/drained cutover.
