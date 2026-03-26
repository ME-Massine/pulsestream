# Kafka Topology Diagram

This diagram shows how PulseStream uses Kafka topics to decouple producers and consumers across the telemetry pipeline.

```mermaid
flowchart LR
    A[IoT Devices / Simulator] --> B[Ingestion Service]
    B --> T1[(telemetry.events.raw)]

    T1 --> C[telemetry-processor]

    C --> T2[(telemetry.events.processed)]
    C --> T3[(telemetry.events.anomalies)]
    C --> T4[(telemetry.events.dlq)]

    T2 --> D[Query Service / Downstream Consumers]
    T3 --> E[Alerting / Dashboard / Query Service]
    T4 --> F[DLQ Inspection / Replay Tools]
```

### Topic Definitions

| Topic                | Producer                                | Consumer                                  | Purpose                           |
|----------------------|-----------------------------------------|-------------------------------------------|-----------------------------------|
| `telemetry.events.raw`      | Ingestion Service                       | telemetry-processor                       | Raw incoming telemetry events     |
| `telemetry.events.processed`| telemetry-processor                     | Query Service / downstream consumers      | Normalized and enriched telemetry data |
| `telemetry.events.anomalies`| telemetry-processor                     | Dashboard / alerting / query service      | Detected anomaly events           |
| `telemetry.events.dlq`| Ingestion Service or telemetry-processor | Replay or inspection tools                | Invalid or failed events          |

### Notes

*   `telemetry.events.raw` is the primary ingestion topic.
*   `telemetry.events.processed` allows downstream consumers to use cleaned telemetry without duplicating processing logic.
*   `telemetry.events.anomalies` isolates anomaly events from normal telemetry flow.
*   `telemetry.events.dlq` supports resilience and recovery workflows.
