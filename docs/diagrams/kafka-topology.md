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
    T4 -->|operator-triggered replay listener| C

    T2 -.-> D[Future query / downstream consumers]
    T3 -.-> E[Future alerting / query consumers]
```

### Topic Definitions

| Topic                | Producer                                | Consumer                                  | Purpose                           |
|----------------------|-----------------------------------------|-------------------------------------------|-----------------------------------|
| `telemetry.events.raw`      | Ingestion Service                       | telemetry-processor                       | Raw incoming telemetry events     |
| `telemetry.events.processed`| telemetry-processor                     | Future query / downstream consumers | Normalized and enriched telemetry data |
| `telemetry.events.anomalies`| telemetry-processor                     | Future alerting / query consumers | Detected anomaly events           |
| `telemetry.events.dlq`| telemetry-processor | telemetry-processor replay listener / inspection | Invalid or failed events          |

### Notes

*   `telemetry.events.raw` is the primary ingestion topic.
*   `telemetry.events.processed` allows downstream consumers to use cleaned telemetry without duplicating processing logic.
*   `telemetry.events.anomalies` isolates anomaly events from normal telemetry flow.
*   `telemetry.events.dlq` captures failed events. The telemetry processor routes failures here and can replay them back into the pipeline via a management endpoint (bounded, snapshot-based replay sessions).
