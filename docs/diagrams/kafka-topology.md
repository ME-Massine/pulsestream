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

    T2 --> D[Query Service / Downstream Consumers planned]
    T3 --> E[Alerting / Dashboard / Query Service planned]
    T4 --> F[DLQ Inspection / Replay Tools planned]
```

### Topic Definitions

| Topic                | Producer                                | Consumer                                  | Purpose                           |
|----------------------|-----------------------------------------|-------------------------------------------|-----------------------------------|
| `telemetry.events.raw`      | Ingestion Service                       | telemetry-processor                       | Raw incoming telemetry events     |
| `telemetry.events.processed`| telemetry-processor                     | Planned Query Service / downstream consumers | Normalized and enriched telemetry data |
| `telemetry.events.anomalies`| telemetry-processor                     | Planned dashboard / alerting / query service | Detected anomaly events           |
| `telemetry.events.dlq`| Planned failure-routing producers | Planned replay or inspection tools        | Invalid or failed events          |

### Notes

*   `telemetry.events.raw` is the primary ingestion topic.
*   `telemetry.events.processed` allows downstream consumers to use cleaned telemetry without duplicating processing logic.
*   `telemetry.events.anomalies` isolates anomaly events from normal telemetry flow.
*   `telemetry.events.dlq` is provisioned for future resilience and recovery workflows.
