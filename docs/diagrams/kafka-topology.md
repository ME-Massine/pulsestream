# Kafka Topology Diagram

This diagram shows how PulseStream uses Kafka topics to decouple producers and consumers across the telemetry pipeline.

```mermaid
flowchart LR
    A[IoT Devices / Simulator] --> B[Ingestion Service]
    B --> T1[(telemetry.events.raw)]

    T1 --> C[Telemetry Processor]

    C --> T2[(telemetry.events.processed)]
    C --> T3[(telemetry.events.anomalies)]
    C --> T4[(telemetry.events.dlq)]

    T2 --> D[Query Service / Downstream Consumers]
    T3 --> E[Query Service / Monitoring Dashboards / Future Alerting]
    T4 --> F[DLQ Inspection / Replay Tools]
```

### Topic Definitions

| Topic                        | Producer                                | Consumer                                  | Purpose                           |
|------------------------------|-----------------------------------------|-------------------------------------------|-----------------------------------|
| `telemetry.events.raw`       | Ingestion Service                       | Telemetry Processor                       | Raw incoming telemetry events     |
| `telemetry.events.processed` | Telemetry Processor                     | Query Service / downstream consumers      | Normalized and enriched telemetry data |
| `telemetry.events.anomalies` | Telemetry Processor                     | Query Service / Monitoring Dashboards / Future Alerting | Detected anomaly events           |
| `telemetry.events.dlq`       | Ingestion Service or Telemetry Processor | Replay or inspection tools                | Invalid or failed events          |

### Notes

*   `telemetry.events.raw` is the primary ingestion topic.
*   `telemetry.events.processed` allows downstream consumers to use cleaned telemetry without duplicating processing logic.
*   `telemetry.events.anomalies` isolates anomaly events from normal telemetry flow.
*   `telemetry.events.dlq` supports resilience and recovery workflows.
