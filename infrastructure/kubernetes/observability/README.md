# OpenTelemetry Collector on Kubernetes

Trace collection and forwarding for the `PulseStream` platform (#157).

The platform services are already instrumented — both `ingestion-service` and `telemetry-processor` carry the OpenTelemetry Spring Boot starter and export OTLP over `http/protobuf`. In the cluster they had nowhere to export **to**: `application.yml` falls back to `http://localhost:4318`, which is correct under Docker Compose (the service and Jaeger share a host) and resolves to the service's own pod in Kubernetes. These manifests deploy the collector that becomes that destination, and point the two exporting services at it.

## Manifests

| File | Purpose |
| :--- | :--- |
| `namespace.yaml` | The `observability` namespace. Its automatic `kubernetes.io/metadata.name` label is what the NetworkPolicy egress rules match on. |
| `serviceaccount.yaml` | Dedicated ServiceAccount with **no** RBAC and no mounted API token — the pipeline never calls the Kubernetes API. |
| `configmap.yaml` | The collector pipeline: OTLP receivers, `memory_limiter` + `batch` processors, `debug` exporter, `health_check` extension. |
| `deployment.yaml` | Two stateless replicas, non-root, read-only root filesystem. |
| `service.yaml` | ClusterIP `otel-collector` publishing `4317` (gRPC) and `4318` (HTTP). |

## Pipeline

```
ingestion-service    ─┐
                      ├─ OTLP/HTTP :4318 ─> memory_limiter ─> batch ─> debug (stdout)
telemetry-processor  ─┘
```

**Traces terminate in the `debug` exporter today.** No trace backend runs in the cluster yet — Jaeger is still marked *planned* in [`docs/diagrams/kubernetes-deployment.md`](../../../docs/diagrams/kubernetes-deployment.md) and is deployed by its own issue. Aiming an `otlp` exporter at a Service that does not exist would leave the collector retrying and queueing every batch it accepts, so the pipeline ends in `debug`, which writes one line per exported batch to the collector's stdout. That is enough to prove the services reach the collector, and it is what the verification below reads.

When the backend lands, the change is confined to `configmap.yaml`: add the exporter and list it in the traces pipeline. No service manifest changes — that indirection is the reason to run a collector at all.

`query-service` is **not** connected. It has no `otel` configuration in `application.yml` and emits no spans, so it gets no OTLP endpoint and no egress hole.

## Deploy

```powershell
kubectl apply -f infrastructure/kubernetes/observability/namespace.yaml
kubectl apply -f infrastructure/kubernetes/observability/
```

The namespace is applied first because everything else is namespaced into it; `kubectl apply -f <dir>` does not order its files.

Then roll the exporting services so they pick up the new ConfigMap key — a running pod keeps the environment it started with:

```powershell
kubectl rollout restart deployment/ingestion-service
kubectl rollout restart deployment/telemetry-processor
```

If the NetworkPolicies are applied, re-apply the two that gained an OTLP egress rule:

```powershell
kubectl apply -f infrastructure/kubernetes/network-policies/ingestion-service.yaml
kubectl apply -f infrastructure/kubernetes/network-policies/telemetry-processor.yaml
```

## Verify

**1. The collector is running.**

```powershell
kubectl get pods -n observability -l app.kubernetes.io/name=otel-collector
kubectl logs -n observability -l app.kubernetes.io/name=otel-collector | Select-String "Everything is ready"
```

**2. The configuration is valid.** The collector binary validates a config without starting a pipeline:

```powershell
kubectl exec -n observability deploy/otel-collector -- /otelcol-contrib validate --config=/conf/collector.yaml
```

An invalid pipeline also fails loudly at startup — the container exits and `kubectl logs` names the offending component — so a `Running` pod is itself evidence the config parsed.

**3. Services can export.** Send one event through the ingest API, then read the collector's stdout:

```powershell
kubectl port-forward svc/ingestion-service 8081:8081
# in another shell
curl.exe -X POST http://localhost:8081/api/v1/events -H "Content-Type: application/json" -d '{\"deviceId\":\"device-1\",\"metric\":\"temperature\",\"value\":21.5,\"timestamp\":\"2026-01-01T00:00:00Z\"}'

kubectl logs -n observability -l app.kubernetes.io/name=otel-collector --tail=50 | Select-String "TracesExporter"
```

A `TracesExporter` line with a non-zero span count means the span left the service, crossed the pod network, and was accepted. Allow up to the `batch` processor's 5s timeout before it appears.

If nothing arrives, the service side names the reason — the SDK logs its export failures in the service's own log, not the collector's:

```powershell
kubectl logs deploy/ingestion-service | Select-String -Pattern "otlp|Failed to export"
```

## Operational notes

- **A ConfigMap edit does not reload the collector.** It reads `collector.yaml` once at start. Apply a change with `kubectl rollout restart deployment/otel-collector -n observability`.
- **`memory_limiter` percentages are relative to the container memory limit** in `deployment.yaml`. Changing the limit without revisiting the percentages changes the point at which the collector sheds load.
- **`verbosity: detailed`** on the debug exporter prints every span and attribute. It is useful for a minute and fills a node's log disk over an hour.
- **Nothing buffers spans while the collector is down.** Traces are diagnostic data; the event pipeline (Kafka) is unaffected, because the SDK exporters are non-blocking and drop after their own retry.

## Out of scope

Sampling strategies (head or tail) and multi-tenant routing are explicitly excluded by #157. Both change the deployment shape: tail-based sampling requires every span of a trace to reach the same collector instance, which means a `loadbalancing` exporter in front of the sampling collectors rather than the flat two-replica Deployment here.
