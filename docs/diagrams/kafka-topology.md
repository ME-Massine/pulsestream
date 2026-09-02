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
    T4 --> C

    T2 --> D[Query Service scaffold / downstream consumers]
    T3 --> E[Alerting / Dashboard / Query Service scaffold]
    T4 --> F[DLQ replay endpoint on telemetry-processor]
```

### Topic Definitions

| Topic                | Producer                                | Consumer                                  | Purpose                           |
|----------------------|-----------------------------------------|-------------------------------------------|-----------------------------------|
| `telemetry.events.raw`      | Ingestion Service                       | telemetry-processor                       | Raw incoming telemetry events     |
| `telemetry.events.processed`| telemetry-processor                     | Query Service (scaffold) / downstream consumers | Normalized and enriched telemetry data |
| `telemetry.events.anomalies`| telemetry-processor                     | Query Service (scaffold) / future alerting consumers | Detected anomaly events           |
| `telemetry.events.dlq`| telemetry-processor | telemetry-processor replay endpoint / inspection | Invalid or failed events          |

### Notes

*   `telemetry.events.raw` is the primary ingestion topic.
*   `telemetry.events.processed` allows downstream consumers to use cleaned telemetry without duplicating processing logic.
*   `telemetry.events.anomalies` isolates anomaly events from normal telemetry flow.
*   `telemetry.events.dlq` captures failed events. The telemetry processor routes failures here and can replay them back into the pipeline via a management endpoint (bounded, snapshot-based replay sessions).
