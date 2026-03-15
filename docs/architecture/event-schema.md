# Event Schema Specification

## Overview

PulseStream is an event-driven platform. All services communicate through events transported by Kafka. To ensure consistency and interoperability between services, all events follow a standardized envelope structure.

This document defines the canonical event schema used across the platform.

---

## Event Envelope

Every event published to the streaming platform must follow the canonical event envelope.

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

Produced after the telemetry processor normalizes or enriches telemetry data.

*   `telemetry.processed`

#### Anomaly Events

Generated when telemetry readings violate anomaly rules.

*   `telemetry.anomaly.detected`

#### Dead Letter Events

Generated when event processing fails.

*   `telemetry.deadletter`

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

| Field      | Description                   |
|------------|-------------------------------|
| deviceId   | Unique device identifier      |
| deviceType | Type of sensor                |
| metric     | Type of measurement           |
| value      | Sensor reading                |
| unit       | Measurement unit              |
| location   | Logical device location       |

### Anomaly Event Example

When the telemetry processor detects abnormal behavior, it emits an anomaly event.

```json
{
"eventId": "evt_203",
"tenantId": "factory_01",
"eventType": "telemetry.anomaly.detected",
"timestamp": "2026-03-15T12:05:23Z",
"source": "telemetry-processor",
"version": "1.0",
"payload": {
"deviceId": "sensor_1042",
"metric": "temperature",
"value": 52.3,
"threshold": 45.0,
"anomalyType": "threshold_breach",
"severity": "high"
}
}
```

### Anomaly Types

The platform initially supports the following anomaly types.

#### Threshold Breach

Triggered when a sensor reading exceeds predefined limits.

Example:

*   `temperature > 45°C`

#### Sudden Deviation

Triggered when the value changes significantly in a short time interval.

Example:

*   `temperature jump from 20 → 40 within seconds`

#### Missing Heartbeat

Triggered when a device fails to report telemetry within its expected interval.

### Kafka Topic Mapping

Events are routed through Kafka topics.

| Topic                 | Purpose                       |
|-----------------------|-------------------------------|
| `telemetry.raw`       | Raw telemetry events          |
| `telemetry.processed` | Normalized telemetry events   |
| `telemetry.anomalies` | Detected anomalies            |
| `telemetry.deadletter`| Failed events                 |

### Event Versioning

Event schemas may evolve over time. To support backward compatibility, each event includes a version field.

Guidelines:

*   Schema changes must be backward compatible whenever possible
*   New fields should be optional
*   Existing fields should not change semantics
*   Consumers should tolerate unknown fields

### Schema Evolution Strategy

Future improvements may include:

*   JSON Schema validation
*   Schema Registry integration
*   Avro or Protobuf event serialization

For the MVP, events will use JSON encoding.

### Event Validation

Events received by the ingestion service must pass basic validation checks:

*   required envelope fields present
*   valid timestamp format
*   payload structure matches event type
*   metric values within acceptable bounds

Invalid events are redirected to the dead letter topic.

## Summary

This schema specification defines the contract between all PulseStream services.

By enforcing a consistent event structure, the platform ensures:

*   interoperability between services
*   reliable event processing
*   safe schema evolution
*   simplified debugging and monitoring
