# Event Flow Diagram

This diagram illustrates the lifecycle of a telemetry event as it moves through the PulseStream platform.

```mermaid
sequenceDiagram
    participant Device as IoT Device / Simulator
    participant Ingestion as Ingestion Service
    participant KafkaRaw as Kafka Topic: telemetry.events.raw
    participant Processor as Telemetry Processor
    participant KafkaOut as Kafka Topics: processed / anomalies
    participant DB as PostgreSQL
    participant Query as Query Service
    participant Dashboard as Dashboard / API Client

    Device->>Ingestion: POST /telemetry event
    Ingestion->>Ingestion: Validate schema
    Ingestion->>KafkaRaw: Publish telemetry.reading
    KafkaRaw->>Processor: Consume telemetry.reading
    Processor->>Processor: Normalize reading
    Processor->>Processor: Apply anomaly detection
    Processor->>KafkaOut: Publish processed / anomaly events
    Processor->>DB: Store processed telemetry
    Processor->>DB: Store anomaly record (if detected)
    Query->>DB: Read telemetry and anomaly data
    Dashboard->>Query: Request metrics / anomalies
    Query->>Dashboard: Return response
```

**Notes:**

*   The platform receives telemetry over HTTP through the ingestion service.
*   Kafka decouples telemetry producers from downstream consumers.
*   The telemetry processor applies anomaly detection rules asynchronously.
*   The processor publishes results to output topics (`telemetry.events.processed`, `telemetry.events.anomalies`) before persisting to PostgreSQL.
*   Processed results are stored in PostgreSQL and later exposed through query APIs.
