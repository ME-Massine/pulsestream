# System Architecture Diagram

This diagram shows the high-level architecture of PulseStream and the main interactions between its components.

```mermaid
flowchart LR
    A[IoT Devices / Simulator] --> B[Ingestion Service]
    B --> T1[(Kafka Topic: telemetry.events.raw)]

    T1 --> C[Telemetry Processor]
    C --> T2[(Kafka Topic: telemetry.events.processed)]
    C --> T3[(Kafka Topic: telemetry.events.anomalies)]
    C --> T4[(Kafka Topic: telemetry.events.dlq)]

    C --> D[PostgreSQL]
    D --> E[Query Service]
    E --> F[Dashboard / API Clients]

    subgraph Observability
        P[Prometheus]
        G[Grafana]
        O[OpenTelemetry]
        J[Jaeger]
    end

    B --> P
    C --> P
    E --> P

    B --> O
    C --> O
    E --> O

    P --> G
    O --> J
```

**Notes:**

*   `telemetry.events.raw` stores incoming telemetry readings.

*   `telemetry.events.processed` stores normalized or enriched downstream events.

*   `telemetry.events.anomalies` captures anomaly detection results.

*   `telemetry.events.dlq` stores invalid or failed events.
