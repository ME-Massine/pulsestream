# Autoscaling Validation

## Overview

[`autoscaling-strategy.md`](autoscaling-strategy.md) states what the platform's autoscalers are *configured* to do. This document covers the other half: how that configuration is proven to hold on a running cluster, what counts as a pass, and which runs have actually been recorded.

The distinction matters because the two are checked by different things and fail in different ways:

| | Checks | Needs | Fails when |
| :--- | :--- | :--- | :--- |
| **Structural** — `scripts/validate-ingestion-hpa.ps1`, `scripts/validate-telemetry-processor-hpa.ps1` | The HPA object's shape: scale target, bounds, metric, target percentage, both stabilization windows | A cluster with the HPA applied, or nothing at all for the offline `scripts/tests/test-*-hpa-structure.ps1` variants | Someone edits a manifest away from the documented decision |
| **Behavioral** — `scripts/validate-autoscaling-behavior.ps1` (this document) | What the autoscaler *did*: replicas rose under load, the ceiling and floor held, the stabilization window was waited out, the service stayed available throughout | A cluster with `metrics-server`, the workload deployed, and enough capacity to run the extra replicas | The configuration is right on paper but does not produce the intended behavior under real traffic |

A structural check passing tells you nothing about whether the autoscaler works. An HPA can be perfectly shaped and still report `<unknown>` forever because `metrics-server` is missing — which is the failure mode that most resembles success, since a service that never scales looks exactly like a service that is never busy.

---

## What the behavioral run asserts

`scripts/validate-autoscaling-behavior.ps1` records a timeline of samples — replica count, ready count, CPU utilization against target, every other metric the HPA is configured with, and container restarts — across three phases (idle, under load, after load), then applies these rules. They live in `scripts/lib/PulseStreamAutoscalingBehavior.psm1` as pure functions, so `scripts/tests/test-autoscaling-behavior-analysis.ps1` exercises each of them against synthetic timelines with no cluster involved.

| Assertion | Why it is a failure |
| :--- | :--- |
| Every sample after the first carries a CPU reading | `<unknown>` means the HPA is blind. Nothing else in the run means anything, and the symptom is indistinguishable from an idle service |
| Every sample after the first reports `ScalingActive=True` on the HPA | A CPU reading and a changing replica count show that the Deployment was resized, not who resized it. A rollout, a `kubectl scale`, or another controller produces the same timeline. `ScalingActive` is the autoscaler stating that it computed the desired count from the metric and wrote it to the scale subresource, so it is what attributes the replica changes to the HPA. The status is recorded on every line of the run report, not just summarised in the verdict |
| Replicas rose above the baseline | The point of the run. If they did not, either the load never crossed the target or the autoscaler did not act |
| Every replica of the peak became `Ready` | A replica count is a request; capacity is what became `Ready`. Scaled-up Pods that stay `Pending` for want of node memory, or that never pass their readiness probe, are counted by `spec.replicas` and carry no traffic — so a run that "scaled" 2 → 6 while `Ready` stayed at 2 has proved that the HPA can write a number and nothing about the platform's ability to absorb load. `Ready` lagging the replica count *during* a scale-up is normal and does not fail the run; capacity that never arrives does |
| Replicas never exceeded `maxReplicas` | The ceiling encodes downstream capacity — 3 topic partitions for the processor, node and partition capacity for ingestion — not a soft preference |
| At least `minReplicas` pods were `Ready` in every sample | "Services remain healthy during scale events", measured as *ready* pods rather than scheduled ones. A new pod that is `Running` but not `Ready` is not serving |
| No container restarted during the run | A restart under load means the scale event did not keep the existing pods healthy. Only the containers present in the *first* sample carry a historical baseline, since those Pods predate the run and their counts have nothing to do with it. A Pod the autoscaler creates mid-run starts from zero — otherwise a new replica that crash-looped before it was first sampled would be baselined at its own restart count and reported as a clean run |
| *(scale-down runs only)* The workload returned to `minReplicas`, and the first scale-in came no earlier than the configured stabilization window *after the HPA first recommended fewer replicas* | The stabilization window is the one part of `spec.behavior` a structural check cannot prove. A window that does not hold turns a GC or JIT dip into a scale-in, and for the processor every scale-in is a consumer group rebalance. What the window is measured **from** decides the verdict — see [Where the stabilization window starts](#where-the-stabilization-window-starts) |

The scale-down assertions are opt-in (`-IncludeScaleDown`) because they cost the full 300-second window plus one step per replica. The window is read from the applied HPA rather than hardcoded, so the assertion tracks the manifest instead of drifting from it.

### Where the stabilization window starts

Kubernetes stabilizes *recommendations*, not metrics: the controller computes a desired replica count each cycle and, on the way down, holds the workload at the maximum recommendation inside the window. So the window can only be measured from the moment the HPA first recommends fewer replicas than are running — which is not the moment utilization drops below target, and the two can be minutes apart.

The desired count is the controller's own arithmetic, reproduced in `Get-HpaScaleRecommendation`:

```text
desiredReplicas = ceil(measuredPods * currentMetricValue / targetValue)   per metric
                  with metric-specific missing-Pod fallbacks
                  maximum across all configured metrics
                  clamped into [minReplicas, maxReplicas]
                  no change at all while |ratio - 1| <= tolerance   (default 0.1)
```

Each step of that keeps a workload at its current size while the metric sits under target:

| At 6 replicas, 70% target | Desired | Scale-in recommended? |
| :--- | :--- | :--- |
| 69% | 6 | No — inside the 0.1 tolerance, so the controller proposes no change |
| 62% | 6 | No — outside the tolerance, but `ceil(6 × 62 / 70) = 6` |
| 58% | 5 | Yes — the first reading that produces a smaller count |
| 5%, with a second metric at its target | 6 | No — the desired count is the **maximum** across metrics |
| 5%, with a second metric reading `<unknown>` | — | No — a controller that cannot read a metric does not scale in on it |

Anchoring on "utilization last at or above target" instead would credit a run with the whole sub-target stretch. A workload idling at 69% for 150 seconds, collapsing to 10%, and scaling in 60 seconds later would be scored as a 270-second window and accepted against the configured 300-second one. `scripts/tests/test-autoscaling-behavior-analysis.ps1` carries that exact timeline as a regression case, along with a recommendation that dips and recovers (which restarts the window, since the controller stabilizes on the maximum) and a scale-in that no recommendation preceded at all (which is rejected outright rather than credited to the window).

Every metric the applied HPA carries is sampled, not just CPU: `Get-HpaMetricReadings` pairs each `spec.metrics` entry with its `status.currentMetrics` reading, converting Kubernetes quantities (`100m`, `512Mi`) to a common base first. Pod coverage is tracked per metric. The harness obtains CPU coverage from `kubectl top`; coverage for an optional custom per-Pod metric is unknown unless independently observed, so that sample cannot establish a downscale anchor. Reusing CPU coverage would be unsafe because metrics-server and a custom-metrics adapter can see different Pods.

That has an operational consequence worth stating plainly: **`-IncludeScaleDown` cannot produce a scale-down verdict against [`ingestion-service-hpa-custom-metrics.yaml`](../../infrastructure/kubernetes/autoscaling/ingestion-service-hpa-custom-metrics.yaml)**, because its `http_requests_per_second` metric has no sampled coverage and therefore blocks the recommendation on every sample. The run fails naming that metric and saying the window was unmeasurable — not "something else resized the Deployment", which is the other way a run reaches the verdict with no anchor and is the opposite diagnosis. Judge scale-down against the CPU-only [`hpa.yaml`](../../infrastructure/kubernetes/ingestion-service/hpa.yaml), or sample the custom metric's coverage independently first. Every assertion before the scale-down one is unaffected and still runs. `-HpaTolerance` overrides the assumed 0.1 for a cluster whose `kube-controller-manager` runs a different `--horizontal-pod-autoscaler-tolerance`.

#### Why the divisor is not the replica count

`measuredPods`, not `currentReplicas`, is the divisor because that is the number the controller uses — and the difference decides the verdict on a cluster that cannot schedule every replica it is asked for.

`replica_calculator.go` averages only the Pods that are `Ready` **and** have a metric, publishes exactly that average to `status.currentMetrics`, and *then* makes two adjustments the status never shows:

- it divides by the number of Pods it averaged, not by `currentReplicas`;
- on the way down it substitutes a conservative value for every Pod whose metric is missing, re-checks the tolerance on the adjusted ratio, and abandons the change outright if the adjustment reversed its direction. For CPU utilization, Kubernetes uses `max(100, targetUtilization)%` of the Pod request; at a 70% target the normalized fallback is therefore `100/70`, not `1.0`.

Reading `status.currentMetrics` back out against `currentReplicas` therefore computes something the controller never did, and it errs in the dangerous direction: it invents scale-in recommendations, which anchor the stabilization window early and pass a window that never held. At 4 Ready replicas with CPU at 40% of a 70% target and only 3 Pods reporting, the naive form proposes `ceil(4 × 40/70) = 3`. The controller fills the missing Pod at 100% of its request, giving `(0.571×3 + 1.429)/4 = 0.786` and `ceil(0.786 × 4) = 4` — no scale-in at all.

Nothing in the HPA's status says whether the Pods left out of an average were unready or merely missing that metric, and the two produce different numbers, so `Get-HpaScaleRecommendation` evaluates both worlds and takes the **larger** proposal. The result is an upper bound on the controller's own recommendation, which makes the scale-in verdict one-sided in the only direction that matters: it is never true unless the controller would have recommended a scale-in too. For CPU, the sampler bounds `measuredPods` from the Deployment's `readyReplicas` and CPU-specific `kubectl top pods` coverage. It never lends that count to another configured metric; unknown per-metric coverage yields no downscale anchor.

### Sampling grace

The observed scale-down delay is quantized by sampling: a pod removed 299 seconds after the recommendation turned over, seen by a sampler running every 15 seconds, is the 300-second window working correctly. The harness subtracts a grace period from the expected window before comparing — twice the requested sampling interval (minimum 30s).

That grace is widened by exactly one thing: **the gap that ends at the anchor sample**. The recommendation turned over somewhere inside that gap, so the real window can be up to that much longer than what was measured. Every other property of the sampling either says nothing about this measurement or biases it the other way — the scale-in happened at or before the sample that first saw it, which makes the observed delay too *long*, and is not forgiven.

The widest gap *anywhere* in the timeline is the wrong number, and the reason is concrete: a run that stalled for 299 seconds between two idle post-load samples and then scaled in 60 seconds after the recommendation turned over has said nothing about the 300-second window, but a grace taken from the widest gap would forgive the whole window and pass it. `Get-ScaleDownSamplingGrace` owns this rule so that `scripts/tests/test-autoscaling-behavior-analysis.ps1` can hold it to it offline, and that exact timeline is one of its regression cases.

The grace is capped at half the stabilization window. Past that the run has stopped being evidence about the window at all, so it is rejected rather than passed on a grace that forgives most of what it is measuring; the same ceiling is applied to the requested grace in preflight, before load starts. Every run report records the requested interval, the widest observed gap, the gap before the scale-in recommendation, and the grace the verdict used.

Preflight also derives minimum phase lengths from the applied HPA policies. The load phase must span the slowest scale-up policy interval plus two observations; an opted-in scale-down timeout must cover the stabilization window, one conservative policy interval for every possible replica step, and a final observation at the floor. A short run therefore fails before load starts instead of producing a misleading "did not scale" verdict.

---

## Load, and why it is real traffic

Both load generators drive the service's actual work path. A CPU burner would move the metric and prove only that the HPA can read a number.

| Workload | Load | Path exercised |
| :--- | :--- | :--- |
| `ingestion-service` | In-cluster `curl` pods running concurrent `POST /api/v1/events` loops against the ClusterIP Service | Deserialization, validation, and the produce to `telemetry.events.raw` |
| `telemetry-processor` | A rate-limited `kafka-console-producer` per load pod, publishing valid `TelemetryEvent` JSON into `telemetry.events.raw` | Consumption, anomaly detection, the Postgres insert, and the republish to `telemetry.events.processed` / `telemetry.events.anomalies` |

The processor's payload alternates each device's reading between `20.5` and `95.5`, so consecutive readings for the same device cross both the `MAX_TEMPERATURE` threshold and the 50% spike ratio in `TelemetryAnomalyDetectionService`. That keeps every event on the expensive path rather than the cheap one, which is what makes CPU move at all.

Telemetry uses one producer with a 350 events/s scale-up burst for 45 seconds, then a 50 events/s maintenance rate for the rest of the load phase. The burst moves CPU past the HPA target; the maintenance rate keeps heartbeat/liveness verification meaningful without continuing to build backlog after scale-up. The three values are configurable with `-KafkaBurstEventsPerSecond`, `-KafkaBurstDurationSeconds`, and `-KafkaEventsPerSecond`. Ingestion uses one lightweight curl pod with 16 concurrent request loops. Passing `-LoadPodCount` overrides either service default. This bounded shape keeps the normal run focused on HPA behavior: multiple unbounded generators can create backlog faster than the platform can drain it and starve a laptop-class single-node cluster, which turns the validation into an accidental stress test. Increase load only when the reported peak remains below the applied CPU target.

Every generated `eventId` carries both the run id and the load pod's ordinal. Without the ordinal, a multi-pod run would make each generator emit the same id sequence — which exercises the platform's persistence de-duplication path rather than representative traffic, and makes the CPU the HPA reads the cost of rejecting duplicates. The default is one load pod; the ordinal keeps explicit `-LoadPodCount` overrides correct.

Each load pod prints a pod-global, monotonically rising traffic counter to its log: the HTTP generator's request loops append to one shared counter file that a reporter prints every 5 seconds, and the Kafka generator's single producer already has one. The harness reads that counter alongside **every** sample of the load phase and fails the run once a pod has been stuck at the same value for longer than two sampling intervals (minimum 60s), then requires every pod to end the phase ahead of where it started. Checking only once, before sampling begins, would let a generator heartbeat once and hang — and the resulting timeline would read as "the autoscaler did not react" rather than "there was no load".

Load-pod lifecycle, bootstrap, and heartbeat handling live in `scripts/lib/PulseStreamAutoscalingLoad.psm1`, keeping the top-level script focused on the validation phases. Multiline commands are base64-encoded to survive Windows PowerShell 5.1 native-command quoting; the pod bootstrap checks for `base64` first and emits an exact prerequisite error when an overridden image does not provide it. `scripts/tests/test-autoscaling-load-helpers.ps1` verifies template rendering, command round-tripping, the prerequisite diagnostic, and heartbeat parsing without a cluster.

Load pods carry a run-scoped label and are deleted in a `finally` block, so an interrupted run does not leave traffic generators hammering the cluster.

---

## Running it

Prerequisites, in order — each one fails the run with a specific message rather than producing an empty timeline:

1. **`metrics-server` installed and `Available`.** On kind and Docker Desktop it also needs `--kubelet-insecure-tls`, because their kubelets serve self-signed certificates. Confirm with `kubectl top nodes` before anything else.
2. **The workload and its HPA applied**, and the corresponding structural validator already passing. This script assumes the shape is correct and only measures behavior.
3. **Cluster capacity for the extra replicas.** Each replica requests `512Mi`; a single-node cluster near its memory ceiling will leave scaled-up pods `Pending`, and the run fails on the Ready-capacity assertion rather than reporting a scale-up the cluster never delivered. Check the node's free requests (`kubectl describe node`) against `maxReplicas × 512Mi` before starting, and free capacity — or lower the load so the HPA settles at a count the node can run — if there is not enough.

```powershell
# Scale-up only (~5 minutes)
pwsh -File scripts/validate-autoscaling-behavior.ps1 -Service ingestion-service

# Scale-up and the full return to minReplicas (~20 minutes), writing a report
pwsh -File scripts/validate-autoscaling-behavior.ps1 `
    -Service telemetry-processor `
    -IncludeScaleDown `
    -ReportPath infrastructure/kubernetes/telemetry-processor/hpa-behavior-runtime-verification.md
```

If peak utilization never crosses the target, raise `-LoadConcurrency` or `-LoadPodCount` for ingestion, or `-KafkaBurstEventsPerSecond` for telemetry. Keep the smallest load that crosses the target: this is behavioral validation, not a stress test.

---

## Recorded runs

| Workload | Evidence | Scale-up | Scale-down to floor | Notes |
| :--- | :--- | :--- | :--- | :--- |
| `ingestion-service` | [`hpa-behavior-runtime-verification.md`](../../infrastructure/kubernetes/ingestion-service/hpa-behavior-runtime-verification.md) | 2 → 4 → 6; peak 218% against the 70% target; all 6 replicas became Ready | Yes; 263s from the first scale-in recommendation (6 replicas at 55%, desiring 5) to the scale-in with 56s of anchor-local grace, then 6 → 5 → 4 → 3 → 2 | `ScalingActive=True` throughout, Ready ≥2, zero restarts, cleanup confirmed |
| `telemetry-processor` | [`hpa-behavior-runtime-verification.md`](../../infrastructure/kubernetes/telemetry-processor/hpa-behavior-runtime-verification.md) | 2 → 3; peak 166% against the 70% target; all 3 replicas became Ready | Yes; 289s from the first scale-in recommendation (3 replicas at 20%, desiring the floor) to the scale-in with 30s of grace, then 3 → 2 | `ScalingActive=True` throughout, Ready ≥2, zero restarts, cleanup confirmed |

Both reports were generated by `validate-autoscaling-behavior.ps1 -IncludeScaleDown` from tested code revision `b99b49e396f1bdd0dabf018b135ef1dfe089db01`, on a clean working tree. Re-running the harness on each cluster the platform is deployed to is the intended use, with the generated report committed next to the manifest it describes.

The ingestion run used 6 concurrent request loops and reached the six-replica ceiling with every replica Ready. Telemetry used a 500 events/s burst for 45 seconds, then the bounded 50 events/s maintenance rate, and reached its three-replica partition ceiling with every replica Ready. Both runs prove that the autoscaler reacted, the requested capacity became available, the bounds held, and the configured scale-down window was respected.

---

## Limitations

- **Not a benchmark.** The run proves the autoscaler reacts correctly; it does not measure throughput, latency, or the cost of a consumer group rebalance. The 300-second scale-down window remains a safety margin rather than a derived value.
- **Thresholds are still conventions.** A passing run does not calibrate the 70% target or the per-replica capacity numbers — it confirms the configured values behave as configured. Turning them into measured values needs a sustained load profile, which belongs to #277 ("define representative telemetry workloads and success thresholds") and is excluded here by #153's own Out of Scope section. [`autoscaling-strategy.md`](autoscaling-strategy.md) records the same split.
- **Scale-down is judged on CPU-covered HPAs only.** The window is anchored to the HPA's own recommendation, which needs per-Pod coverage for every configured metric, and the harness samples coverage for CPU alone. An HPA carrying a custom per-Pod metric can still be validated for scale-up; its scale-down window cannot be measured until that metric's coverage is sampled too.
- **Single-cluster evidence.** Every recorded run is from a local single-node cluster. Scheduling behavior, metric latency, and node capacity all differ on a multi-node cluster.
- **CNI-dependent side effects are not covered.** NetworkPolicies are inert on kind and Docker Desktop (see [`network-policies/README.md`](../../infrastructure/kubernetes/network-policies/README.md)), so a run there cannot show whether a scaled-up pod is reachable under an enforcing CNI.

---

## Related Documentation

- [Autoscaling Strategy](autoscaling-strategy.md) — the targets, bounds, and the reasoning behind them
- [Kafka Topics](topics.md) — the partition count that bounds consumer scaling
- [Services](services.md) — service boundaries and responsibilities
