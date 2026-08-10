# telemetry-processor on Kubernetes

Manifests for the `PulseStream` stream consumer, and the documented way to observe and validate its autoscaling.

| File | Purpose |
| --- | --- |
| `deployment.yaml` | The workload: two replicas, probes, resource limits, pinned image tag. |
| `hpa.yaml` | `HorizontalPodAutoscaler` scaling the Deployment between 2 and 3 replicas on CPU utilization. |
| `configmap.yaml` | Non-sensitive runtime configuration consumed via `envFrom`. |
| `service.yaml` | `ClusterIP` Service `telemetry-processor` — the in-cluster DNS name for probes and metrics. |
| `secret.example.yaml` | Shape of the `telemetry-processor-secret` Secret. Provisioned out-of-band; the real Secret is never committed. |

Apply the directory as a whole:

```bash
kubectl apply -f infrastructure/kubernetes/telemetry-processor/
```

## Autoscaling

`hpa.yaml` scales the `telemetry-processor` Deployment on CPU utilization against the pod's `250m` request, at a 70% target (~`175m`), within a **2 to 3** replica range. The reasoning behind the metric and the bounds lives in [`docs/architecture/autoscaling-strategy.md`](../../../docs/architecture/autoscaling-strategy.md); the two points that matter most when reading the manifest:

- **3 is a hard ceiling, not a tuning choice.** `telemetry.events.raw` has 3 partitions and `PULSESTREAM_KAFKA_CONSUMER_CONCURRENCY` defaults to `1`, so each replica consumes exactly one partition. A fourth replica joins the consumer group, receives no partition assignment, and does no work. Raising `maxReplicas` requires repartitioning the topic first.
- **CPU is the supported signal, not the ideal one.** Consumer-group lag measures the actual backlog, but it is not exported as a Prometheus metric yet (#272) and an HPA cannot read an external metric without a custom metrics adapter or KEDA (#152). CPU comes from the standard `metrics-server` resource API, which is why it is what is wired up today.

### Prerequisite: metrics-server

The HPA reads from the `metrics.k8s.io` API. Without `metrics-server` installed and healthy, it reports `unknown` for its current metric and never scales:

```bash
kubectl top pods -l app.kubernetes.io/name=telemetry-processor
```

### Known caveat: anomaly history is per-replica (#269)

Sudden-deviation detection keeps the previous reading per `tenant:device:metric` in an in-memory map inside each replica (`TelemetryAnomalyDetectionService`), and raw events are keyed by event identifier rather than by device. A scale event triggers a consumer group rebalance, which reassigns partitions and discards the history held by the replica that lost them.

The practical exposure: threshold rules (missing fields, temperature bounds) are unaffected and stay correct; spike detection can miss the comparison for the first reading of a device after a rebalance. The narrow 2-3 range and the 300-second scale-down stabilization window keep rebalances rare, but they do not eliminate this. It is fixed by making state ownership and partitioning device-stable (#269), not by autoscaler configuration.

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

The same checks run without a cluster against the committed manifest:

```bash
pwsh ./scripts/tests/test-telemetry-processor-hpa-structure.ps1
```
