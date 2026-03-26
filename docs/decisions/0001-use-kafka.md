# ADR 0001: Use Apache Kafka as the event streaming backbone

## Status
Accepted

## Context

PulseStream is a cloud-native IoT telemetry and anomaly detection platform.
The system must ingest telemetry events from multiple producers, transport them reliably, and allow multiple downstream consumers to process the same data independently.

The platform requires:

- asynchronous communication between services
- durable event storage
- scalable throughput
- support for multiple consumer groups
- ability to replay historical events
- clear decoupling between ingestion and processing components

A simple synchronous request chain would tightly couple services and reduce resilience.
A basic message queue would support asynchronous delivery, but may not provide the throughput, replay, and stream-processing characteristics needed for the platform.

## Decision

PulseStream will use **Apache Kafka** as the central event streaming backbone.

Kafka will be used to:

- receive raw telemetry events
- decouple producers from processors
- support multiple consumer groups
- buffer events during downstream slowdowns
- enable replay of historical events
- separate normal, processed, anomalous, and dead-letter flows through dedicated topics

Initial topic design:

- `telemetry.events.raw`
- `telemetry.events.processed`
- `telemetry.events.anomalies`
- `telemetry.events.dlq`

## Consequences

### Positive

- Strong decoupling between services
- Durable event storage
- High throughput for telemetry workloads
- Native support for replay
- Easy horizontal scaling for consumers
- Realistic distributed systems architecture

### Negative

- Higher operational complexity than simpler messaging systems
- Local development environment becomes heavier
- Topic, partition, and consumer-group design must be managed carefully
- Debugging asynchronous flows is more complex than synchronous flows

## Alternatives Considered

### RabbitMQ

RabbitMQ is strong for traditional messaging and task distribution, but it is less aligned with the streaming and replay requirements of PulseStream.

Rejected because:

- replay is not a primary strength
- stream-oriented telemetry processing is less natural
- partitioned horizontal scaling is less central to its model

### Direct synchronous communication

Rejected because:

- creates tight coupling
- reduces resilience
- makes downstream failures affect ingestion
- does not support replay or fan-out well

## Notes

Kafka is a core architectural choice and affects service design, observability, scaling strategy, and reliability features such as dead-letter handling and replay.