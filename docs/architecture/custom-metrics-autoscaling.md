# Custom Metrics for Autoscaling

## Overview

[Autoscaling Strategy](autoscaling-strategy.md) selects CPU utilization as the initial scaling signal and states plainly why: it is the only signal available without new cluster components. It also names the two metrics it would rather use — Kafka consumer lag for `telemetry-processor`, request rate for `ingestion-service` — and defers both, because an HPA cannot read either one without a metrics adapter.

This document defines that adapter path and is the design record for issue #152. It covers which advanced metric each service scales on, which component exposes it to the Kubernetes HPA, what has to exist in the cluster before any of it works, and what is deliberately not delivered yet.

The configuration that implements it lives in [`infrastructure/kubernetes/autoscaling/`](../../infrastructure/kubernetes/autoscaling/). One HPA consumes an advanced metric: `ingestion-service`, on request rate. Consumer lag is specified here in full but no HPA consumes it, for reasons in [Consumer lag: specified, not applied](#consumer-lag-specified-not-applied).

Nothing here re-tunes the thresholds in the strategy document. As there, every number is a documented starting point to be corrected by measurement (issue #153), not a calibrated value.

---

## Why CPU Is Not Enough

CPU utilization answers "how hard is this pod working", which is a proxy for "how much work is arriving" only when the two are tightly coupled. For an event-driven platform they come apart in both directions:

- **A saturated consumer can look idle.** `telemetry-processor` spends much of its time waiting — on a Kafka fetch, on a PostgreSQL write. A replica with a 40 000-event backlog and a slow database sits at low CPU. The signal that matters, backlog, is invisible to `metrics.k8s.io`.
- **A busy pod is not necessarily an overloaded one.** A freshly started JVM burns CPU on JIT compilation for its first seconds. To a CPU-driven HPA that is indistinguishable from load, which is the scale-up cascade risk already recorded in the strategy document.
- **CPU has no unit the platform reasons in.** "70% of a 250m request" cannot be compared against a capacity target, an SLO, or a queue depth. "50 requests per second per replica" and "20 000 events of lag" can.

CPU stays in place as a floor signal. The advanced metrics are added *alongside* it, not instead of it — see [Two Metrics on One HPA](#two-metrics-on-one-hpa).

---

## Candidate Metrics

| Metric | Source | Fits | Verdict |
| :--- | :--- | :--- | :--- |
| `kafka_consumergroup_lag` | Strimzi Kafka Exporter | `telemetry-processor` | **Preferred signal.** Measures backlog directly. Not applied — see below |
| `http_server_requests_seconds_count` (rate) | Micrometer / Actuator, already exposed | `ingestion-service` | **Selected and applied.** Measures arriving work in the unit the gateway is specified in |
| `http_server_requests_seconds_max` (latency) | Micrometer / Actuator | `ingestion-service` | Rejected as a *scaling* trigger: latency is an outcome, and scaling on it reacts after users are affected. Keep it for alerting |
| `spring_kafka_listener_seconds` (processing time) | Micrometer / Actuator | `telemetry-processor` | Rejected: per-record processing time is roughly constant under load; it rises when the *database* is slow, and adding consumer replicas makes that worse |
| JVM heap usage | Micrometer / Actuator | all | Rejected for the same reason memory utilization is rejected in the strategy document: the JVM does not return heap, so the signal never falls |

### Selected: request rate for `ingestion-service`

`ingestion-service` is the only service the strategy document autoscales today, and its load is defined as inbound HTTP request rate. Micrometer already exports `http_server_requests_seconds_count` on `/actuator/prometheus` — no service change is needed, which is what makes this the metric that can ship now.

The adapter exposes it as a **pod** metric named `http_requests_per_second`, computed as a 2-minute rate summed per pod:

```promql
sum(rate(http_server_requests_seconds_count{namespace="default",pod=~"ingestion-service-.*"}[2m])) by (pod)
```

A 2-minute window is a deliberate compromise. Shorter (30s) tracks bursts closely but makes the HPA react to single-scrape noise; longer (5m) is stable but delays scale-up past the point where the backlog is already growing. Two minutes covers eight 15-second scrapes.

### Consumer lag: specified, not applied

Lag is the right signal for the processor and this document specifies its adapter rule in full, but no HPA consumes it in this change. Two reasons, neither of them inside the scope of #152:

1. **The metric does not exist yet.** No component in the cluster exports `kafka_consumergroup_lag`. The Kafka CR (`infrastructure/kubernetes/kafka/kafka-cluster.yaml`) enables only the Topic Operator; Strimzi's Kafka Exporter is not configured, and the services do not export lag themselves (issue #272). Nothing downstream can be built on a series that is not produced.
2. **The gain is one replica step.** `telemetry-processor` already autoscales on CPU within `[2, 3]` (issue #151), and 3 is the partition count, not a tuning choice. A backlog signal earns its complexity across a wide range; across a single step, the choice of signal changes *when* the one scale event happens, not how far it goes.

There is a third consideration that lag does not resolve either way: the processor's anomaly history is per-replica and its partitioning key is not device-stable, so every scale event abandons in-memory history on the losing replica (issue #269). That limitation is documented and accepted in the strategy document for the CPU-driven HPA, and switching the trigger to lag neither fixes nor worsens it.

So the lag rule ships in the adapter configuration, where it matches no series and is inert, and the HPA does not. When #272 lands, the remaining work is one manifest and a measured threshold, not a redesign.

---

## Adapter: prometheus-adapter, not KEDA

An HPA cannot read Prometheus. It reads three APIs — `metrics.k8s.io` (resource), `custom.metrics.k8s.io` (custom), `external.metrics.k8s.io` (external) — and something has to serve the latter two.

| | prometheus-adapter | KEDA |
| :--- | :--- | :--- |
| What it is | An extension API server registered as an `APIService` | An operator with its own CRDs (`ScaledObject`) that generates HPAs |
| Scaling API | The HPA stays the API. Manifests are plain `autoscaling/v2` | `ScaledObject` becomes the API; the generated HPA is an implementation detail |
| Sources | Prometheus only | Prometheus, Kafka, SQS, cron, ~60 scalers |
| Scale to zero | No | Yes |
| Added components | One Deployment + `APIService` | Operator, metrics server, admission webhooks, CRDs |

**Chosen: prometheus-adapter.**

KEDA's two real advantages are scale-to-zero and native scalers that skip Prometheus. Neither applies here. The replica floor is 2 everywhere and is an availability decision, so zero is not reachable by design; and a Kafka scaler that queries the broker directly duplicates a metrics pipeline the platform is building anyway for its dashboards.

Against that, prometheus-adapter keeps the scaling surface as ordinary `autoscaling/v2` manifests. The `kubectl get hpa` output, the structural validation scripts, and the reasoning already recorded in the strategy document stay valid; the only change is that one of the HPA's metrics arrives from a different API. Adopting KEDA would replace an object the repository already validates with a CRD it does not.

This is not a permanent decision. If the platform later needs event-source-driven scaling that Prometheus cannot express, or scale-to-zero for a batch workload, KEDA is the right answer and can adopt the same PromQL.

### Which API surface

| Metric | API | Why |
| :--- | :--- | :--- |
| `http_requests_per_second` | `custom.metrics.k8s.io` (Pods) | The metric belongs to specific pods, so the HPA can divide by replica count and compare against a per-replica target |
| `kafka_consumergroup_lag` | `external.metrics.k8s.io` | Lag is a property of a consumer group and a topic, not of any pod. Attaching it to pods would be a lie the adapter would have to invent labels to tell |

---

## Data Path

```text
ingestion-service pods                                     HPA controller
  /actuator/prometheus                                          │
        │  scrape (15s)                                         │ sync (15s)
        ▼                                                       ▼
    Prometheus  ──── PromQL ────►  prometheus-adapter  ──►  custom.metrics.k8s.io
   (in-cluster)                    (APIService)             external.metrics.k8s.io
        ▲
        │  scrape (15s)
   Kafka Exporter (not enabled yet — #272)
```

Every hop adds delay, and the delays add up rather than overlap: a 15-second scrape interval, a 2-minute rate window, and a 15-second HPA sync mean a step change in traffic is fully reflected in the HPA's view somewhere between 30 and 150 seconds later. That is the cost of a custom metric and the reason CPU stays on the same HPA as a faster-moving floor.

---

## Two Metrics on One HPA

`ingestion-service-hpa-custom-metrics.yaml` lists both CPU and request rate. The HPA controller computes a desired replica count from **each** metric independently and takes the **highest** one. The practical consequences are worth stating, because they are what makes this safe:

- **Either signal can trigger a scale-up alone.** Slow requests that burn CPU without raising throughput scale up on CPU; a flood of cheap requests scales up on rate.
- **Scale-down needs both to agree.** The maximum only falls when every metric's recommendation falls, so a quiet period on one signal cannot shrink the deployment while the other is still elevated.
- **An unavailable metric blocks scale-down, not scale-up.** If the adapter is unreachable, the HPA cannot compute that metric, sets `ScalingActive=False`, and refuses to scale down; it can still scale up on the metrics it did read. An adapter outage therefore freezes the replica count at or above its current value rather than collapsing the deployment. This is why CPU stays on the HPA: it makes the custom metric an addition, not a dependency.

### Choosing the request-rate target

`averageValue: 50` — 50 requests per second per replica — with no load test behind it. It is derived from the CPU target already in the strategy document rather than invented independently:

> The CPU target is 70% of a `250m` request, i.e. ~`175m` of CPU per replica. At 50 requests per second, that budget corresponds to ~3.5 ms of CPU per request (`175m ÷ 50`).

So the two metrics on the HPA are set to cross at roughly the same load *if* a request costs about 3.5 ms of CPU. If real requests are cheaper, the rate metric triggers first and becomes the effective signal; if they are more expensive, CPU triggers first and the rate metric is a backstop. Either outcome is informative, which is the point of running both before #153 produces measured numbers.

---

## Cluster Prerequisites

In addition to the prerequisites in the strategy document (`metrics-server`, CPU requests on every autoscaled pod):

1. **Prometheus must run in the cluster and scrape the service pods.** The repository's Prometheus configuration today is Compose-only (`infrastructure/docker/prometheus/prometheus.yml`) and scrapes a static host target. An in-cluster Prometheus with pod discovery is a prerequisite of this path and is not delivered by #152 — see [`infrastructure/kubernetes/autoscaling/README.md`](../../infrastructure/kubernetes/autoscaling/README.md) for the minimum it must satisfy: the `namespace` and `pod` labels must be present on the series, or the adapter cannot map a metric to a pod.
2. **prometheus-adapter must be installed and its `APIService` Available.** `custom.metrics.k8s.io/v1beta1` is served by exactly one thing in a cluster. If another adapter is already registered, installing a second one silently takes the API over.
3. **The adapter's rules must match the metric names the services actually export.** A rule that matches no series produces no error — the metric simply does not appear in the API, and the HPA reports `<unknown>`.

`scripts/validate-custom-metrics-autoscaling.ps1` checks all three against a live cluster.

---

## Rollout and Rollback

Order matters, because an HPA that references a metric nobody serves reports `<unknown>` and stops scaling *down* until it is fixed.

1. Install in-cluster Prometheus; confirm `ingestion-service` pods are scraped and the series carry `namespace` and `pod` labels.
2. Install prometheus-adapter with `infrastructure/kubernetes/autoscaling/prometheus-adapter-values.yaml`.
3. Confirm the metric resolves **before** touching any HPA:
   ```bash
   kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/pods/*/http_requests_per_second"
   ```
4. Replace the CPU-only HPA with the custom-metrics one. Both manifests describe the *same* HPA object, so this is one apply and the Deployment is never left without an autoscaler — and **exactly one HPA may target a Deployment**, because two of them fight, each undoing the other's decision:
   ```bash
   kubectl apply -f infrastructure/kubernetes/autoscaling/ingestion-service-hpa-custom-metrics.yaml
   ```
5. Confirm both metrics report real values, not `<unknown>`.

**Rollback is the same command with the CPU-only manifest**, and it is always available: that HPA has no dependency on Prometheus or the adapter, so falling back restores autoscaling even when the metrics pipeline is entirely down.

```bash
kubectl apply -f infrastructure/kubernetes/ingestion-service/hpa.yaml
```

The same property has a sharp edge worth stating: re-applying the service directory as a whole (`kubectl apply -f infrastructure/kubernetes/ingestion-service/`) reverts a switched-over cluster to CPU-only autoscaling, silently. That is why the custom-metrics manifest lives in `infrastructure/kubernetes/autoscaling/` and not beside the Deployment — a directory apply must not pick up two descriptions of one object.

---

## Validation

| What | How | Cluster required |
| :--- | :--- | :--- |
| The custom-metrics HPA has the documented shape | `scripts/tests/test-custom-metrics-hpa-structure.ps1` | No |
| Metrics APIs registered, adapter healthy, metric resolves, exactly one HPA per target, HPA reading real values | `scripts/validate-custom-metrics-autoscaling.ps1` | Yes |
| The autoscaler actually reacts to load | Issue #153 | Yes |

The structural test reads the committed manifest and asserts the same things the cluster validator asserts about the applied object, so a manifest edit that changes the metric name or the target cannot pass unnoticed.

---

## Limitations

- **No calibrated target.** 50 rps/replica is derived from the CPU target, not measured. Issue #153 replaces it.
- **The preferred signal is still absent.** Consumer lag remains unexported (#272), so the metric this document argues is the right one for a consumer is not in use anywhere. `telemetry-processor` continues to scale on CPU, under-reacting to a backlog that does not raise CPU.
- **In-cluster Prometheus is a prerequisite, not a deliverable.** Until it exists, the adapter configuration here is inert and the custom-metrics HPA must not be applied.
- **The metrics pipeline is a single point of dependency.** Prometheus is one instance; when it is down the HPA loses the custom metric. The failure mode is bounded (no scale-down, CPU still scales up), but it is a real reduction in autoscaling quality.
- **Metric age.** A step change in load takes 30–150 seconds to be fully visible to the HPA. Bursts shorter than that are absorbed by replicas already running, not by scaling.
- **Rules are a compatibility surface.** The adapter rules hard-code Micrometer's metric name. A Spring Boot or Micrometer upgrade that renames `http_server_requests_seconds_count` breaks the metric silently — the API returns nothing rather than an error.

---

## Follow-Up Work

| Issue | Work | Relationship to this document |
| :--- | :--- | :--- |
| #153 | Validate autoscaling behavior end-to-end | Replaces the derived 50 rps target with a measured one |
| #269 | Deterministic anomaly detection under scaling | Independent of the metric, but it bounds how freely the processor may scale at all |
| #272 | Processing and consumer-lag metrics | Produces the series the lag rule here is waiting for |
| #154+ | Kafka and platform metrics integration | Provides the in-cluster Prometheus this path depends on |

---

## Related Documentation

- [Autoscaling Strategy](autoscaling-strategy.md) — targets, bounds, and the CPU baseline this extends
- [`infrastructure/kubernetes/autoscaling/README.md`](../../infrastructure/kubernetes/autoscaling/README.md) — install, verify, and rollback runbook
- [Kafka Topics](topics.md) — partition counts that bound consumer scaling
- [System Overview](system-overview.md) — platform data flow
