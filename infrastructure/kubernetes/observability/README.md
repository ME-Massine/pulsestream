# Tracing on Kubernetes

Trace collection and forwarding for the `PulseStream` platform (#157), and the backend that stores and displays them (#158).

The platform services are already instrumented — both `ingestion-service` and `telemetry-processor` carry the OpenTelemetry Spring Boot starter and export OTLP over `http/protobuf`. In the cluster they had nowhere to export **to**: `application.yml` falls back to `http://localhost:4318`, which is correct under Docker Compose (the service and Jaeger share a host) and resolves to the service's own pod in Kubernetes. These manifests deploy the collector that becomes that destination, and point the two exporting services at it.

## Manifests

| File | Purpose |
| :--- | :--- |
| `namespace.yaml` | The `observability` namespace. Its automatic `kubernetes.io/metadata.name` label is what the NetworkPolicy egress rules match on. |
| `serviceaccount.yaml` | Dedicated ServiceAccount with **no** RBAC and no mounted API token — the pipeline never calls the Kubernetes API. |
| `configmap.yaml` | The collector pipeline: OTLP receivers, `memory_limiter` + `batch` processors, `otlp/jaeger` + `debug` exporters, `health_check` extension. |
| `deployment.yaml` | Two stateless replicas, non-root, read-only root filesystem. Image `0.159.0`, pinned by digest. |
| `service.yaml` | ClusterIP `otel-collector` publishing `4317` (gRPC) and `4318` (HTTP). |
| `jaeger-serviceaccount.yaml` | ServiceAccount for the backend, also without RBAC or a mounted token. |
| `jaeger-deployment.yaml` | Jaeger `all-in-one`, one replica, in-memory storage capped at 50 000 traces. Image `1.60`, pinned by digest. |
| `jaeger-service.yaml` | ClusterIP `jaeger` publishing `4317` (collector ingest) and `16686` (query API and UI). |

## Pipeline

```
ingestion-service    ─┐                                          ┌─> otlp/jaeger ─> Jaeger ─> UI :16686
                      ├─ OTLP/HTTP :4318 ─> memory_limiter ─> batch
telemetry-processor  ─┘                                          └─> debug ─> collector stdout
```

The services only ever know about the collector. Moving or replacing the backend is an edit to `configmap.yaml`; no service manifest changes, which is the reason to route through a collector at all.

**`debug` stays in the pipeline alongside the backend.** It is the signal that survives Jaeger being down: a batch that reached the collector is logged whether or not the backend accepted it, which separates "the service never exported" from "the backend rejected it". At `verbosity: basic` it costs one log line per batch.

**Jaeger stores traces in memory.** They are lost on every restart and reschedule, and `MEMORY_MAX_TRACES` caps what is retained — at 50 000 *traces*, which is a count and not a byte budget. Per-trace size varies with span count and attribute payload, so that number does not guarantee the pod stays under its 1Gi limit; it bounds usage at 50 000 x average trace size, which is a quantity to watch rather than assume. Durable storage is a backend decision (Elasticsearch or Cassandra) that this repository has not made, and long-term retention tuning is out of scope for #158.

`query-service` is **not** connected. It has no `otel` configuration in `application.yml` and emits no spans, so it gets no OTLP endpoint and no egress hole.

## Deploy

```powershell
kubectl apply -f infrastructure/kubernetes/observability/namespace.yaml
kubectl apply -f infrastructure/kubernetes/observability/
```

The namespace is applied first because everything else is namespaced into it; `kubectl apply -f <dir>` does not order its files.

`kubectl apply -f <dir>` also applies the Jaeger manifests in the same pass. The collector tolerates starting first — it retries the export until the backend answers.

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

**3. Traces are visible in the UI.** Port-forward the query port and open it:

```powershell
kubectl port-forward -n observability svc/jaeger 16686:16686
# http://localhost:16686 -> pick `ingestion-service` in the Service dropdown
```

**4. The end-to-end path works.** The repository's existing tracing validator takes both endpoints as parameters, so it runs against the cluster unchanged — port-forward the ingest API and the Jaeger UI in two shells, then:

```powershell
kubectl port-forward svc/ingestion-service 8081:8081
kubectl port-forward -n observability svc/jaeger 16686:16686

pwsh -File scripts/validate-distributed-tracing.ps1 `
    -IngestionBaseUrl http://localhost:8081 `
    -JaegerBaseUrl http://localhost:16686
```

It posts one event, then asserts the ingestion trace carries the HTTP server span and the Kafka producer span, and that `telemetry-processor` emits its own consumer trace **for that same event**. The processor side is correlated by `messaging.kafka.message.key`, which ingestion sets to the event id (`KafkaProducerService.resolveMessageKey`) and the spring-kafka instrumentation records on the consumer span — so traffic this run did not generate cannot satisfy the check.

> **Known failure, and it is a real one.** The producer-span assertion does not pass against the cluster today: `ingestion-service` builds its own `DefaultKafkaProducerFactory` beans in `KafkaProducerConfiguration`, so the OpenTelemetry starter's `ProducerFactoryCustomizer` — which only reaches the factory Spring Boot auto-configures — never wraps them, and no Kafka producer span is emitted. The span is missing from the service, not from this pipeline: the ingestion trace, the processor's consumer trace and the collector-to-Jaeger hop all work. Instrumenting those hand-built factories is service-side work and is tracked separately.

**5. Spans reach the collector.** Useful when step 4 fails and the question is which hop broke. Send one event through the ingest API, then read the collector's stdout:

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

A non-zero `"spans"` count means the span left the service, crossed the pod network, and was accepted. Allow up to the `batch` processor's 5s timeout before it appears. If that line is present but the UI is empty, the break is between the collector and Jaeger, and the collector log names the export error.

If nothing arrives, the service side names the reason — the SDK logs its export failures in the service's own log, not the collector's:

```powershell
kubectl logs deploy/ingestion-service | Select-String -Pattern "otlp|Failed to export"
```

**6. The OTLP egress rules are shaped correctly.** The structural NetworkPolicy validator covers the two rules added here:

```powershell
.\scripts\validate-network-policies.ps1
```

It asserts that `ingestion-service` and `telemetry-processor` each reach the collector on TCP 4318 with the namespace and pod selectors on a *single* peer, and that `query-service` has no 4318 egress. That check is CNI-independent, so unlike step 5 it is meaningful on a dev cluster whose CNI does not enforce policy — where a missing or over-wide rule is invisible because nothing is blocked either way. The offline equivalent, which needs no cluster at all, is `scripts/tests/test-network-policy-structure.ps1`.

## Operational notes

- **A ConfigMap edit does not reload the collector.** It reads `collector.yaml` once at start. Apply a change with `kubectl rollout restart deployment/otel-collector -n observability`.
- **`memory_limiter` percentages are relative to the container memory limit** in `deployment.yaml`. Changing the limit without revisiting the percentages changes the point at which the collector sheds load.
- **`verbosity: detailed`** on the debug exporter prints every span and attribute. It is useful for a minute and fills a node's log disk over an hour.
- **Both images are pinned by digest**, with the tag kept beside it for readability. The digest is what resolves, so a retagged upstream `0.159.0` or `1.60` cannot change the deployed bytes. Bump both halves together — `docker buildx imagetools inspect <image>:<tag>` prints the manifest list digest to use — and re-run the verification above, since the debug exporter's log format is version-dependent.
- **`MEMORY_MAX_TRACES` is a trace count, not a memory limit.** Jaeger evicts the oldest entry once the count is reached and never measures their size, so the pod's 1Gi limit is the only bound enforced in bytes. Crossing it is an OOM kill, which discards every retained trace.
- **Nothing buffers spans while the collector is down.** Traces are diagnostic data; the event pipeline (Kafka) is unaffected, because the SDK exporters are non-blocking and drop after their own retry.

## Out of scope

A Tempo migration and long-term retention tuning are excluded by #158; both are storage decisions that come with a different backend.

Sampling strategies (head or tail) and multi-tenant routing are explicitly excluded by #157. Both change the deployment shape: tail-based sampling requires every span of a trace to reach the same collector instance, which means a `loadbalancing` exporter in front of the sampling collectors rather than the flat two-replica Deployment here.
