# Kubernetes Deployment Diagram

<<<<<<< Updated upstream
This diagram shows how PulseStream components are deployed inside a Kubernetes cluster. The service, Kafka, autoscaling, NetworkPolicy, monitoring, and observability manifests live under `infrastructure/kubernetes/`.
=======
This diagram shows how PulseStream components are deployed inside a Kubernetes cluster. Manifests for all workloads are committed under [`infrastructure/kubernetes/`](../../infrastructure/kubernetes/), including the platform services, Kafka (via the Strimzi operator), in-cluster observability, autoscaling, and network policies. End-to-end validation against a live target cluster is completed as part of Phase 7.
>>>>>>> Stashed changes

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

        K4 --> S2

        S2 --> DB[(PostgreSQL)]

<<<<<<< Updated upstream
        DB --> S3[Query Service Pod]
=======
        DB --> S3[Query Service Pod scaffold]
>>>>>>> Stashed changes
        S3 --> C[Clients / Dashboards]

        subgraph Observability
            P[Prometheus]
            G[Grafana]
            O[OpenTelemetry Collector]
<<<<<<< Updated upstream
            J[Jaeger]
=======
>>>>>>> Stashed changes
        end

        S1 --> P
        S2 --> P

        S1 --> O
        S2 --> O

        P --> G
    end
```

**Notes:**

<<<<<<< Updated upstream
*   External telemetry would enter through an ingress or API gateway. Today it reaches the cluster through the ingestion-service NodePort (`infrastructure/kubernetes/ingestion-service/service-nodeport.yaml`).
*   Each service runs as one or more pods and scales independently.
*   Kafka is the asynchronous backbone inside the cluster.
*   Prometheus and Grafana run in the cluster in the `monitoring` namespace (`infrastructure/kubernetes/monitoring/`). Prometheus was deployed in #154, Grafana in #155, and the Prometheus datasource and dashboards were provisioned in #156.
*   OpenTelemetry tracing runs in the cluster. Services export spans to the collector in the `observability` namespace (#157), which forwards them to the Jaeger backend deployed alongside it (#158). Both live in `infrastructure/kubernetes/observability/`.
*   PostgreSQL provides durable storage for processed telemetry. Anomaly persistence is planned.
=======
*   External telemetry enters through an ingress or API gateway; the ingestion service is also exposed via a NodePort service for cluster testing.
*   Each service runs as one or more pods and scales independently; CPU-based and custom-metrics Horizontal Pod Autoscalers are committed.
*   Kafka is the asynchronous backbone inside the cluster, deployed via the Strimzi operator.
*   Network policies restrict service-to-service traffic to the required paths.
*   Prometheus scrapes service metrics into Grafana dashboards; OpenTelemetry traces are collected by an in-cluster OpenTelemetry Collector.
*   The dead-letter topic (`telemetry.events.dlq`) captures failed events, which the telemetry processor can replay.
*   PostgreSQL provides durable storage for processed telemetry. The `query-service` is deployed as a scaffold; query APIs and anomaly persistence are Phase 7 work.
>>>>>>> Stashed changes
