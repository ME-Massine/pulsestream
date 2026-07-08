# Kubernetes Deployment Diagram

This planned diagram shows how PulseStream components are intended to be deployed inside a Kubernetes cluster. Kubernetes manifests are not present in the current checkout.

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

        DB --> S3[Query Service Pod planned]
        S3 --> C[Clients / Dashboards]

        subgraph Observability
            P[Prometheus]
            G[Grafana]
            O[OpenTelemetry Collector planned]
            J[Jaeger planned]
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

*   External telemetry would enter through an ingress or API gateway.
*   Each service would run as one or more pods and scale independently.
*   Kafka remains the intended asynchronous backbone inside the cluster.
*   Prometheus metrics collection is already part of the local design; OpenTelemetry tracing is planned.
*   PostgreSQL provides durable storage for processed telemetry. Anomaly persistence is planned.
