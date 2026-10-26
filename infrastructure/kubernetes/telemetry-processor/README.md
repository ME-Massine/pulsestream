# telemetry-processor on Kubernetes

Manifests for the `PulseStream` stream consumer, and the documented way to observe and validate its autoscaling.

| File | Purpose |
| --- | --- |
| `deployment.yaml` | The workload: two replicas, probes, resource limits, pinned image tag. |
| `hpa.yaml` | `HorizontalPodAutoscaler` scaling the Deployment between 2 and 3 replicas on CPU utilization. |
| `configmap.yaml` | Non-sensitive runtime configuration consumed via `envFrom`. |
| `service.yaml` | `ClusterIP` Service `telemetry-processor` — the in-cluster DNS name for probes and metrics. |
| `secret.example.yaml` | Shape of the `telemetry-processor-secret` Secret. Provisioned out-of-band; the real Secret is never committed. |

Apply the safe manifests explicitly — do **not** apply the directory as a whole, since it also contains `secret.example.yaml`, and a directory-wide `apply` would create or overwrite the real `telemetry-processor-secret` with the placeholder `REPLACE_ME` credentials it holds:

```bash
kubectl apply -f infrastructure/kubernetes/telemetry-processor/configmap.yaml \
  -f infrastructure/kubernetes/telemetry-processor/service.yaml \
  -f infrastructure/kubernetes/telemetry-processor/deployment.yaml \
  -f infrastructure/kubernetes/telemetry-processor/hpa.yaml
```

Provision the real `telemetry-processor-secret` separately, out-of-band, before applying the manifests above — see `secret.example.yaml` for its shape. Never `kubectl apply -f secret.example.yaml` directly.

## PostgreSQL migrations

PostgreSQL must be reachable before processor startup. The image applies Flyway
migrations automatically before JPA and Kafka listeners initialize, using the
datasource URL in `configmap.yaml` and credentials in the real Secret. The database
role needs database `CREATE` permission and ownership of legacy platform objects.
Replicas serialize migration through Flyway's PostgreSQL lock; no separate Job or
manual SQL is required. Errors prevent startup and readiness.

Follow the same [database migration procedure](../../../docs/architecture/database-migrations.md)
as local development for existing-data adoption, forward-compatible changes,
failure recovery, and rollback. Provision PostgreSQL separately; these manifests
do not create a database server. Promote an image containing the migrations before
expecting this behavior in-cluster. Live cluster validation remains pending.

## Autoscaling

`hpa.yaml` scales the `telemetry-processor` Deployment on CPU utilization against the pod's `250m` request, at a 70% target (~`175m`), within a **2 to 3** replica range. The reasoning behind the metric and the bounds lives in [`docs/architecture/autoscaling-strategy.md`](../../../docs/architecture/autoscaling-strategy.md); the two points that matter most when reading the manifest:

- **3 is the useful ceiling at concurrency one.** Replicas divide the three raw
  partitions; with two replicas, one owns two partitions. At most three consumer
  threads process raw records. Partition changes require a coordinated state and
  capacity migration; raising `maxReplicas` alone adds no partition throughput.
- **CPU is the supported signal, not the ideal one.** Consumer-group lag measures the actual backlog, but it is not exported as a Prometheus metric yet (#272) and an HPA cannot read an external metric without a custom metrics adapter or KEDA (#152). CPU comes from the standard `metrics-server` resource API, which is why it is what is wired up today.

### Prerequisite: metrics-server

The HPA reads from the `metrics.k8s.io` API. Without `metrics-server` installed and healthy, it reports `unknown` for its current metric and never scales:

```bash
kubectl top pods -l app.kubernetes.io/name=telemetry-processor
```

### Durable anomaly history (#269)

Ingestion and replay use tenant/device keys; bounded PostgreSQL reading state and
recent offset decisions survive scaling, restart and rebalance. Flyway V3 creates
the state tables. All replicas must share the database and anomaly settings.

The [operating contract](../../../docs/architecture/anomaly-detection.md) defines
stream-time expiration, hard capacity bounds, units, recovery and the required
paused/drained cutover from old event-ID keys. State failures stop consumption
without acknowledging the failed record; repair the cause and restart. HPA
changes cannot repair a database outage or state-capacity exhaustion. Live target
cluster validation remains pending.

## Observing replica behavior

Watch the autoscaler decide:

```bash
kubectl get hpa telemetry-processor --watch
```

The `TARGETS` column shows current-vs-target CPU, and `REPLICAS` shows the current desired count. Scale decisions and their reasons are recorded as events:

```bash
kubectl describe hpa telemetry-processor
```

Confirm the consumer group actually redistributed partitions after a scale event — a new replica that holds no partition is doing no work:

```bash
kubectl run kafka-group-check --rm -it --restart=Never \
  --image quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 -- \
  bin/kafka-consumer-groups.sh \
    --bootstrap-server pulsestream-kafka-bootstrap:9092 \
    --group telemetry-processor --describe
```

Each `CONSUMER-ID` in that output owns one partition. Three replicas should show three distinct consumers with one partition each; a replica missing from the list is a replica past the ceiling.

## Validating the configuration

The structural checks assert that the applied HPA targets the right Deployment, uses the documented metric and target, stays within the 2-3 range, and reacts fast on scale-up while damping scale-down:

```bash
pwsh ./scripts/validate-telemetry-processor-hpa.ps1
```

They are deliberately independent of cluster load, so they mean something without generating traffic. Proving that the autoscaler reacts to real load requires a cluster with `metrics-server` and a load generator, and is tracked separately (#153).

The same checks — the assertions live in `scripts/lib/PulseStreamAutoscaling.psm1`, so there is one copy of them — run against the committed manifest with no cluster, no `kubectl` and no network:

```bash
pwsh ./scripts/tests/test-telemetry-processor-hpa-structure.ps1
```

That test reads `hpa.yaml` with `scripts/lib/PulseStreamYaml.psm1`, a reader limited to the YAML subset these manifests use; anything outside it (flow collections, anchors, block scalars, multiple documents) throws rather than being misread. Its own coverage is `scripts/tests/test-yaml-parsing.ps1`.
