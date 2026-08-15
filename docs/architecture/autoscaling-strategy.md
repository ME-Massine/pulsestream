# Autoscaling Strategy

## Overview

This document defines which PulseStream services are autoscaling targets, which metrics drive those decisions, and the replica bounds each service is allowed to move within.

It is a design document. No HorizontalPodAutoscaler manifests, metrics adapters, or load tests are introduced here — those are tracked separately (see [Follow-Up Work](#follow-up-work)). The purpose is to fix the targets and thresholds first, so that later manifests implement a decision rather than invent one.

The strategy is deliberately conservative. The platform has no measured load profile yet, so every number below is a documented starting point to be corrected by measurement, not a tuned value.

---

## Current Baseline

This was the baseline the strategy was written against — all three platform services at a fixed replica count, set directly in their Deployment manifests:

| Service | Replicas | CPU request | CPU limit | Memory request | Memory limit |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `ingestion-service` | 2 | `250m` | `1` | `512Mi` | `1Gi` |
| `telemetry-processor` | 2 | `250m` | `1` | `512Mi` | `1Gi` |
| `query-service` | 2 | `250m` | `1` | `512Mi` | `1Gi` |

Two replicas is an availability floor, not a capacity decision: it keeps a service reachable during node drains and rolling updates. Where an HPA now exists, that same `replicas: 2` is its `minReplicas`, so the floor is unchanged and the autoscaler only moves the count upward from it. The resource requests are unchanged by any autoscaling work, and the 70% target below is defined relative to the `250m` request in this table.

---

## Scaling Eligibility

Not every service is a valid autoscaling target. Eligibility is determined by whether a service holds per-replica state and whether adding replicas actually adds throughput.

### ingestion-service — eligible

The ingest gateway is a stateless HTTP endpoint that validates a request and produces to `telemetry.events.raw`. It holds no cross-request state, so replicas are interchangeable and traffic distribution is handled by the existing ClusterIP/NodePort Service.

Load is driven by inbound HTTP request rate, and the work per request (deserialize, validate, produce) is CPU-bound with no blocking downstream call on the request path.

### telemetry-processor — eligible within a hard ceiling

The processor is a Kafka consumer group member. Two independent constraints apply.

**Partition ceiling.** Replicas of a consumer group divide the partitions of the subscribed topic; a replica that is assigned no partition does no work. `telemetry.events.raw` has 3 partitions (see [topics.md](topics.md)), and `PULSESTREAM_KAFKA_CONSUMER_CONCURRENCY` defaults to `1`, so each replica consumes one partition. **The maximum useful replica count is 3.** More generally, useful replicas equal `partitions ÷ concurrency`; raising concurrency lowers the useful replica count proportionally. Scaling past that ceiling burns cluster resources and adds nothing. Throughput beyond 3 replicas requires repartitioning the topic, not a larger HPA maximum.

**Anomaly history is per-replica.** Sudden-deviation detection keeps previous readings in an in-memory `ConcurrentHashMap` inside each replica (`TelemetryAnomalyDetectionService`), and raw events are partitioned by event identifier rather than by stable device identity. Readings for the same device can therefore land on different replicas, and every scale event triggers a consumer group rebalance that reassigns partitions and abandons the in-memory history on the losing replica.

The processor autoscales within `[2, 3]` on CPU utilization (issue #151), with that second constraint accepted as a documented limitation rather than solved. What it costs in practice: threshold rules (missing fields, temperature bounds) are stateless and stay correct, while spike detection can miss the comparison for the first reading of a device after a rebalance. What bounds the cost: the range spans a single replica, so at most one rebalance per scale decision, and the 300-second scale-down window keeps those decisions infrequent. Making the output independent of replica count and rebalance timing requires device-stable partitioning and state ownership (issue #269); no autoscaler setting substitutes for it.

### query-service — deferred

`query-service` is currently a scaffold: an application class, configuration, and a context-load test, with no query endpoints implemented. There is no read traffic to scale against, so an autoscaler would only add moving parts to an idle deployment.

It stays at a fixed 2 replicas. It is expected to become a straightforward CPU-scaled target once the read API exists (issue #266), with the added consideration that its floor is set by the PostgreSQL connection pool rather than by CPU.

### Stateful components — excluded

Kafka, PostgreSQL, and Redis are explicitly **not** autoscaling targets:

- **Kafka** is managed by the Strimzi operator as a KRaft cluster with persistent storage per broker. Broker count changes require partition reassignment and are an operator-driven, deliberate operation — not a metric-driven one.
- **PostgreSQL** is a single instance for the MVP (ADR 0003). Horizontal scaling is a replication topic, not an autoscaling one.
- **Redis** is a single-instance cache with no meaningful load today.

---

## Selected Metrics

### Initial metric: CPU utilization against requests

CPU utilization is the initial signal. The reasoning is not that CPU is the ideal proxy for load, but that it is the only signal available without new cluster components: it comes from the standard `metrics-server` resource metrics API, and the Kubernetes HPA consumes it natively.

The HPA compares average CPU usage against the **request** (`250m`), not the limit. At a 70% target, a replica is considered saturated at roughly `175m` of actual CPU — well inside the `1` CPU limit, which leaves headroom for JVM garbage collection spikes and for the burst that occurs between a new pod being created and it becoming useful.

### Rejected metrics

**Memory utilization.** The JVM reserves heap and does not return it to the operating system under normal operation, so memory utilization rises and stays high regardless of load. As a scaling signal it produces scale-up events that never reverse. Memory stays a limit and an alerting concern, not a scaling trigger.

**Consumer lag.** For `telemetry-processor`, consumer group lag is the correct scaling signal — it measures the actual backlog rather than a proxy for it. It is not usable yet: lag is not exported as a Prometheus metric by the services today (issue #272), and consuming an external metric from an HPA requires a custom metrics adapter or KEDA, which is out of scope here (issue #152). The processor therefore scales on CPU in the meantime, with the understanding that CPU is a weak substitute for a consumer that is often I/O-bound: a processor blocked on Postgres or Kafka accumulates lag without accumulating CPU, so the autoscaler under-reacts to exactly the backlog it exists to drain. The narrow 2-3 range limits what that costs, and the signal is expected to be replaced rather than tuned.

**Request rate (RPS).** Available from Actuator/Micrometer, but it is a custom metric with the same adapter dependency as lag, and it requires a calibrated per-replica capacity number that no load test has produced yet.

> **Update (#152).** The adapter dependency named in both rejections is now designed and configured — see [Custom Metrics for Autoscaling](custom-metrics-autoscaling.md). Request rate is available as an optional second metric on the `ingestion-service` HPA, alongside CPU rather than instead of it, in [`ingestion-service-hpa-custom-metrics.yaml`](../../infrastructure/kubernetes/autoscaling/ingestion-service-hpa-custom-metrics.yaml); its per-replica target is still derived rather than measured, so #153 remains the calibration. Consumer lag has an adapter rule but no HPA, because nothing exports the series yet (#272). The targets and bounds in this document are unchanged by that work.

---

## Targets and Bounds

| Service | Metric | Target | Min | Max | Ceiling rationale |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `ingestion-service` | CPU utilization vs. request | 70% (≈`175m`) | 2 | 6 | Node capacity, and downstream processing capped at 3 partitions |
| `telemetry-processor` | CPU utilization vs. request (consumer lag once #152/#272 land) | 70% (≈`175m`) | 2 | 3 | Hard partition ceiling: 3 partitions ÷ concurrency 1 |
| `query-service` | CPU utilization vs. request | 70% (≈`175m`) | 2 | 4 | Placeholder. **Not autoscaled until the read API exists (#266)** |

### Why these bounds

**Minimum of 2** everywhere. This preserves the existing availability floor. A minimum of 1 would let the autoscaler undo the rolling-update and node-drain safety that the current fixed replica count provides.

**Maximum of 6 for ingestion.** Two limits meet here. First, cluster capacity: at `250m` requested per pod, 6 ingestion replicas plus 2 processor and 2 query replicas request 2.5 CPU before Kafka, PostgreSQL, Redis, and the observability stack are counted — already demanding for a small cluster. Second, and more important, ingestion accepting traffic faster than the processor can drain it does not increase platform throughput; it converts an HTTP-level backlog into Kafka consumer lag. Six is a deliberate ceiling meant to fail visibly as lag rather than silently as dropped requests.

**Maximum of 3 for the processor.** This is not a tuning choice. It is the partition count.

---

## Scaling Behavior

Reaction speed matters as much as the thresholds, because these are JVM services behind a Kafka consumer group.

- **Scale up: react quickly, no stabilization window.** A new Spring Boot pod needs roughly 15–30 seconds before its readiness probe passes (`initialDelaySeconds: 15`), so the autoscaler must act on a sustained rise rather than wait through it.
- **Scale down: 300-second stabilization window.** JVM CPU is spiky — garbage collection and JIT compilation both produce short bursts that a short window misreads as load. The same window protects the processor, since every scale-in triggers a consumer group rebalance that pauses processing across the whole group.
- **Startup CPU is not load.** JIT compilation makes a freshly started JVM CPU-hungry for its first few seconds. Combined with the readiness delay, a pod can be counted in HPA metrics while still warming up, which can cause a scale-up cascade. This is a known risk to verify during autoscaling validation (issue #153).

---

## Cluster Prerequisites

CPU-based autoscaling is not free of dependencies. Before any HPA is applied:

1. **`metrics-server` must be installed and healthy** in the cluster. Resource-metric HPAs read from the `metrics.k8s.io` API; without it, an HPA reports `unknown` for its metric and never scales. This is a plain add-on install, distinct from the custom metrics adapter that is out of scope.
2. **CPU requests must be set on every autoscaled pod.** Utilization is computed as a percentage of the request. All three deployments already set `250m`, so this holds today — but the threshold is defined relative to that value, and changing the request silently changes the effective trigger.

---

## Assumptions

- **Request-relative thresholds.** The 70% target means 70% of the `250m` request. If a Deployment's CPU request is changed, this document's thresholds must be revisited in the same change.
- **Small cluster.** Bounds assume a modest cluster where total requested CPU is a real constraint. On a larger cluster the ingestion ceiling can rise, but only alongside a higher partition count.
- **Partition count is stable at 3.** Every processor bound in this document derives from `telemetry.events.raw` having 3 partitions. Repartitioning invalidates them.
- **Consumer concurrency stays at 1.** `PULSESTREAM_KAFKA_CONSUMER_CONCURRENCY` defaults to `1`. Raising it reduces the useful replica ceiling proportionally.
- **Ingestion load is roughly uniform.** CPU per request is assumed not to vary greatly with payload; large-payload traffic would break the CPU-as-proxy assumption.
- **Vertical scaling is out of scope.** This document covers replica count only. Right-sizing requests and limits is a separate exercise that depends on the same missing measurements.

---

## Limitations

- **No measured load profile yet.** The autoscalers are exercised under real load and their behavior is asserted end-to-end — see [Autoscaling Validation](autoscaling-validation.md) — but that proves the configured values behave as configured, not that they are the right values. The 70% CPU target and ingestion request-rate target remain conventions until #153 records the sustained CPU/RPS profile needed to calibrate them; calibration is assigned to #153, not left out of scope.
- **CPU is a proxy, not the real signal.** For an HTTP gateway it is a reasonable one. For a Kafka consumer it is weak: lag can grow while CPU stays flat, so the processor's autoscaler is expected to under-react until the lag metric replaces it (#152, #272).
- **The processor's anomaly history does not survive a scale event.** Its spike-detection state is per-replica and its partitioning key is not device-stable, so a rebalance drops the previous reading for the devices that moved. Threshold rules are unaffected. The 2-3 range bounds how often this happens; only #269 removes it.
- **Autoscaling does not address Kafka or PostgreSQL capacity.** Scaling ingestion moves the bottleneck downstream to partition count and to a single-instance database. Autoscaling raises the ceiling on one tier only.
- **Rebalance cost is not quantified.** The pause imposed on a consumer group by a scale event has not been measured, so the 300-second scale-down window is a safety margin rather than a derived value.

---

## Follow-Up Work

| Issue | Work | Relationship to this document |
| :--- | :--- | :--- |
| #150 | CPU-based HPA for `ingestion-service` | Implements the ingestion row of the targets table |
| #151 | Autoscaling for consumer services | Implements the processor row on the CPU signal, within the 2-3 partition ceiling |
| #152 | Custom metrics for advanced autoscaling | Delivers the adapter path both rejected metrics depend on. See [Custom Metrics for Autoscaling](custom-metrics-autoscaling.md) |
| #153 | Validate autoscaling behavior end-to-end | Proves the shipped rows behave as configured under load and records the CPU/RPS profile used to replace assumed targets with measured ones. See [Autoscaling Validation](autoscaling-validation.md) |
| #269 | Deterministic anomaly detection under scaling | Removes the per-replica anomaly-history limitation the processor row accepts |
| #272 | Processing and consumer-lag metrics | Prerequisite for #152 |

---

## Related Documentation

- [Custom Metrics for Autoscaling](custom-metrics-autoscaling.md) — the adapter path for request-rate and consumer-lag signals
- [Autoscaling Validation](autoscaling-validation.md) — how the configuration below is proven on a running cluster
- [Kafka Topics](topics.md) — partition counts that bound consumer scaling
- [Services](services.md) — service boundaries and responsibilities
- [Service Discovery](../../infrastructure/kubernetes/service-discovery.md) — how traffic reaches replicas
- [System Overview](system-overview.md) — platform data flow
