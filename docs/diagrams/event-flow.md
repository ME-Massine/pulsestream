# Event Flow Diagram

This diagram illustrates the lifecycle of a telemetry event as it moves through the PulseStream platform.

```mermaid
sequenceDiagram
    participant Device as IoT Device / Simulator
    participant Ingestion as Ingestion Service
    participant Kafka as Kafka Topic: telemetry.events.raw
    participant Processor as telemetry-processor
    participant Processed as Kafka Topic: telemetry.events.processed
    participant Anomalies as Kafka Topic: telemetry.events.anomalies
    participant DB as PostgreSQL
    participant Query as Query Service
    participant Dashboard as Dashboard / API Client

    Device->>Ingestion: POST /api/v1/events
    Ingestion->>Ingestion: Validate schema
    Ingestion->>Kafka: Publish telemetry.reading → telemetry.events.raw
    Kafka->>Processor: Consume telemetry.reading
    Processor->>Processor: Normalize reading
    Processor->>Processor: Apply anomaly detection
    alt Anomaly detected
        Processor->>Anomalies: Publish telemetry.anomaly
    else Normal reading
        Processor->>DB: Store processed telemetry
        Processor->>Processed: Publish telemetry.processed
    end
    Dashboard->>Query: GET /api/v1/telemetry with authenticated tenant principal
    Query->>DB: Read processed telemetry for the authorized tenant
    Query->>Dashboard: Return bounded page
```

**Notes:**

*   The platform receives telemetry over HTTP through the ingestion service.
*   Kafka decouples telemetry producers from downstream consumers.
*   The telemetry-processor applies anomaly detection rules asynchronously.
*   Normal processed telemetry is stored in PostgreSQL.
*   Events that fail processing are routed to `telemetry.events.dlq` and can be replayed back into the pipeline via a management endpoint on the telemetry processor.
*   Anomaly events are currently published to Kafka only; anomaly persistence and queries remain Phase 7 work (#267). The [processed telemetry API](../api/processed-telemetry.md) is implemented (#266), with authenticated tenant integration pending.
