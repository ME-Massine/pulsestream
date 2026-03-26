# Kubernetes Deployment Diagram

This diagram shows how PulseStream components are deployed inside a Kubernetes cluster.

```mermaid
flowchart TB
    U[IoT Devices / Simulator] --> I[Ingress / API Gateway]

    subgraph Kubernetes Cluster
        I --> S1[Ingestion Service Pod]
        S1 --> K1[(Kafka: telemetry.events.raw)]

        K1 --> S2[telemetry-processor Pod]
        S2 --> K2[(Kafka: telemetry.events.processed)]
        S2 --> K3[(Kafka: telemetry.events.anomalies)]
        S2 --> K4[(Kafka: telemetry.events.dlq)]

        S2 --> DB[(PostgreSQL)]

        DB --> S3[Query Service Pod]
        S3 --> C[Clients / Dashboards]

        subgraph Observability
            P[Prometheus]
            G[Grafana]
            O[OpenTelemetry Collector]
            J[Jaeger]
        end

        S1 --> P
        S2 --> P
        S3 --> P

        S1 --> O
        S2 --> O
        S3 --> O

        P --> G
        O --> J
    end
```

**Notes:**

*   External telemetry enters through an ingress or API gateway.
*   Each service runs as one or more pods and can scale independently.
*   Kafka remains the asynchronous backbone inside the cluster.
*   Prometheus and OpenTelemetry collect metrics and traces from all services.
*   PostgreSQL provides durable storage for processed telemetry and anomalies.
