# OpenTelemetry Collector on Kubernetes

Trace collection and forwarding for the `PulseStream` platform (#157).

The platform services are already instrumented — both `ingestion-service` and `telemetry-processor` carry the OpenTelemetry Spring Boot starter and export OTLP over `http/protobuf`. In the cluster they had nowhere to export **to**: `application.yml` falls back to `http://localhost:4318`, which is correct under Docker Compose (the service and Jaeger share a host) and resolves to the service's own pod in Kubernetes. These manifests deploy the collector that becomes that destination, and point the two exporting services at it.

## Manifests

| File | Purpose |
| :--- | :--- |
| `namespace.yaml` | The `observability` namespace. Its automatic `kubernetes.io/metadata.name` label is what the NetworkPolicy egress rules match on. |
| `serviceaccount.yaml` | Dedicated ServiceAccount with **no** RBAC and no mounted API token — the pipeline never calls the Kubernetes API. |
| `configmap.yaml` | The collector pipeline: OTLP receivers, `memory_limiter` + `batch` processors, `debug` exporter, `health_check` extension. |
| `deployment.yaml` | Two stateless replicas, non-root, read-only root filesystem. Image `0.159.0`, pinned by digest. |
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
```

```powershell
# in another shell
$body = @{
    eventId   = [Guid]::NewGuid().ToString()
    tenantId  = "otel-collector-validation"
    eventType = "telemetry.reading"
    timestamp = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    source    = "otel-collector-validation"
    version   = "1.0"
    payload   = @{
        deviceId   = "sensor_1042"
        deviceType = "temperature-sensor"
        metric     = "temperature"
        value      = 21.5
        unit       = "celsius"
        location   = "zone-a"
    }
} | ConvertTo-Json -Depth 5

Invoke-RestMethod -Method Post -Uri "http://localhost:8081/api/v1/events" `
    -ContentType "application/json" -Body $body
```

Every field above is required. `TelemetryIngestionRequestDto` rejects a body that omits one, or that flattens `payload` into the top level, with `400 Bad Request` — and a rejected request never reaches the span-producing path, so a malformed body looks exactly like a broken collector. A `202 Accepted` is the signal to move on. The scripted equivalent of this request is the body built in [`scripts/validate-distributed-tracing.ps1`](../../../scripts/validate-distributed-tracing.ps1).

Then read the collector's stdout:

```powershell
kubectl logs -n observability -l app.kubernetes.io/name=otel-collector --tail=50 |
    Select-String -Pattern 'Traces.*"spans"'
```

The debug exporter logs one line per exported batch, and in collector `0.159.0` that line's message is `Traces` — the `TracesExporter` message of older builds was renamed when component telemetry moved to the `otelcol.component.*` attributes:

```
info  Traces  {"otelcol.component.id": "debug", "otelcol.component.kind": "exporter", "otelcol.signal": "traces", "resource spans": 1, "spans": 3}
```

A non-zero `"spans"` count means the span left the service, crossed the pod network, and was accepted. Allow up to the `batch` processor's 5s timeout before it appears.

If nothing arrives, the service side names the reason — the SDK logs its export failures in the service's own log, not the collector's:

```powershell
kubectl logs deploy/ingestion-service | Select-String -Pattern "otlp|Failed to export"
```

**4. The OTLP egress rules are shaped correctly.** The structural NetworkPolicy validator covers the two rules added here:

```powershell
.\scripts\validate-network-policies.ps1
```

It asserts that `ingestion-service` and `telemetry-processor` each reach the collector on TCP 4318 with the namespace and pod selectors on a *single* peer, and that `query-service` has no 4318 egress. That check is CNI-independent, so unlike step 3 it is meaningful on a dev cluster whose CNI does not enforce policy — where a missing or over-wide rule is invisible because nothing is blocked either way. The offline equivalent, which needs no cluster at all, is `scripts/tests/test-network-policy-structure.ps1`.

## Operational notes

- **A ConfigMap edit does not reload the collector.** It reads `collector.yaml` once at start. Apply a change with `kubectl rollout restart deployment/otel-collector -n observability`.
- **`memory_limiter` percentages are relative to the container memory limit** in `deployment.yaml`. Changing the limit without revisiting the percentages changes the point at which the collector sheds load.
- **`verbosity: detailed`** on the debug exporter prints every span and attribute. It is useful for a minute and fills a node's log disk over an hour.
- **The image is pinned by digest**, with the tag kept beside it for readability. The digest is what resolves, so a retagged upstream `0.159.0` cannot change the deployed bytes. Bump both halves together — `docker buildx imagetools inspect otel/opentelemetry-collector-contrib:<tag>` prints the manifest list digest to use — and re-run the verification below, since the debug exporter's log format is version-dependent.
- **Nothing buffers spans while the collector is down.** Traces are diagnostic data; the event pipeline (Kafka) is unaffected, because the SDK exporters are non-blocking and drop after their own retry.

## Out of scope

Sampling strategies (head or tail) and multi-tenant routing are explicitly excluded by #157. Both change the deployment shape: tail-based sampling requires every span of a trace to reach the same collector instance, which means a `loadbalancing` exporter in front of the sampling collectors rather than the flat two-replica Deployment here.
