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

`scripts/validate-autoscaling-behavior.ps1` records a timeline of samples — replica count, ready count, CPU utilization against target, and container restarts — across three phases (idle, under load, after load), then applies these rules. They live in `scripts/lib/PulseStreamAutoscalingBehavior.psm1` as pure functions, so `scripts/tests/test-autoscaling-behavior-analysis.ps1` exercises each of them against synthetic timelines with no cluster involved.

| Assertion | Why it is a failure |
| :--- | :--- |
| Every sample after the first carries a CPU reading | `<unknown>` means the HPA is blind. Nothing else in the run means anything, and the symptom is indistinguishable from an idle service |
| Every sample after the first reports `ScalingActive=True` on the HPA | A CPU reading and a changing replica count show that the Deployment was resized, not who resized it. A rollout, a `kubectl scale`, or another controller produces the same timeline. `ScalingActive` is the autoscaler stating that it computed the desired count from the metric and wrote it to the scale subresource, so it is what attributes the replica changes to the HPA. The status is recorded on every line of the run report, not just summarised in the verdict |
| Replicas rose above the baseline | The point of the run. If they did not, either the load never crossed the target or the autoscaler did not act |
| Replicas never exceeded `maxReplicas` | The ceiling encodes downstream capacity — 3 topic partitions for the processor, node and partition capacity for ingestion — not a soft preference |
| At least `minReplicas` pods were `Ready` in every sample | "Services remain healthy during scale events", measured as *ready* pods rather than scheduled ones. A new pod that is `Running` but not `Ready` is not serving |
| No container restarted during the run | A restart under load means the scale event did not keep the existing pods healthy. Only the containers present in the *first* sample carry a historical baseline, since those Pods predate the run and their counts have nothing to do with it. A Pod the autoscaler creates mid-run starts from zero — otherwise a new replica that crash-looped before it was first sampled would be baselined at its own restart count and reported as a clean run |
| *(scale-down runs only)* The workload returned to `minReplicas`, and the first scale-in came no earlier than the configured stabilization window | The stabilization window is the one part of `spec.behavior` a structural check cannot prove. A window that does not hold turns a GC or JIT dip into a scale-in, and for the processor every scale-in is a consumer group rebalance |

The scale-down assertions are opt-in (`-IncludeScaleDown`) because they cost the full 300-second window plus one step per replica. The window is read from the applied HPA rather than hardcoded, so the assertion tracks the manifest instead of drifting from it.

### Sampling grace

The observed scale-down delay is quantized by the sampling interval: a pod removed 299 seconds after the load stopped, seen by a sampler running every 15 seconds, is the 300-second window working correctly. The harness subtracts a grace period from the expected window before comparing — twice the requested sampling interval (minimum 30s), widened to the *widest gap the sampler actually achieved* if that was larger. Each sample costs several `kubectl` round trips, and on a node the load has saturated those are slow, so a run asked for 15-second sampling can land 50 seconds apart; judging the window against an interval that was never achieved fails runs whose window in fact held. The grace is only ever subtracted, never added, so a window that is genuinely too short still fails, and a sampler so slow that its gap reaches the window itself fails the run instead of passing it. Every run report records the requested interval, the widest observed gap, and the grace the verdict used.

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

Every generated `eventId` carries both the run id and the load pod's ordinal. Without the ordinal each pod of a run emits the same id sequence, and the default three-pod run would send every event three times — which exercises the platform's persistence de-duplication path rather than representative traffic, and makes the CPU the HPA reads the cost of rejecting duplicates.

Each load pod prints a pod-global, monotonically rising traffic counter to its log: the HTTP generator's request loops append to one shared counter file that a reporter prints every 5 seconds, and the Kafka generator's single producer already has one. The harness reads that counter alongside **every** sample of the load phase and fails the run once a pod has been stuck at the same value for longer than two sampling intervals (minimum 60s), then requires every pod to end the phase ahead of where it started. Checking only once, before sampling begins, would let a generator heartbeat once and hang — and the resulting timeline would read as "the autoscaler did not react" rather than "there was no load".

Load-pod lifecycle, bootstrap, and heartbeat handling live in `scripts/lib/PulseStreamAutoscalingLoad.psm1`, keeping the top-level script focused on the validation phases. Multiline commands are base64-encoded to survive Windows PowerShell 5.1 native-command quoting; the pod bootstrap checks for `base64` first and emits an exact prerequisite error when an overridden image does not provide it. `scripts/tests/test-autoscaling-load-helpers.ps1` verifies template rendering, command round-tripping, the prerequisite diagnostic, and heartbeat parsing without a cluster.

Load pods carry a run-scoped label and are deleted in a `finally` block, so an interrupted run does not leave traffic generators hammering the cluster.

---

## Running it

Prerequisites, in order — each one fails the run with a specific message rather than producing an empty timeline:

1. **`metrics-server` installed and `Available`.** On kind and Docker Desktop it also needs `--kubelet-insecure-tls`, because their kubelets serve self-signed certificates. Confirm with `kubectl top nodes` before anything else.
2. **The workload and its HPA applied**, and the corresponding structural validator already passing. This script assumes the shape is correct and only measures behavior.
3. **Cluster capacity for the extra replicas.** Each replica requests `512Mi`; a single-node cluster near its memory ceiling will leave scaled-up pods `Pending`, which the run correctly reports as a readiness failure rather than an autoscaler failure. See the capacity caveat in the recorded `ingestion-service` run below.

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
| `ingestion-service` | [`hpa-behavior-runtime-verification.md`](../../infrastructure/kubernetes/ingestion-service/hpa-behavior-runtime-verification.md) | 2 → 4 → 6; peak 260% against the 70% target | Yes; first scale-in after 292s, then 6 → 5 → 4 → 3 → 2 | `ScalingActive=True` throughout, Ready ≥2, zero restarts, cleanup confirmed |
| `telemetry-processor` | [`hpa-behavior-runtime-verification.md`](../../infrastructure/kubernetes/telemetry-processor/hpa-behavior-runtime-verification.md) | 2 → 3; peak 135% against the 70% target | Yes; first scale-in after 308s, then 3 → 2 | `ScalingActive=True` throughout, Ready ≥2, zero restarts, cleanup confirmed |

Both reports were generated by `validate-autoscaling-behavior.ps1 -IncludeScaleDown` from tested code revision `adac0572dfe11401583cd16de48e9dcbffb1bf4c`. Re-running the harness on each cluster the platform is deployed to is the intended use, with the generated report committed next to the manifest it describes.

---

## Limitations

- **Not a benchmark.** The run proves the autoscaler reacts correctly; it does not measure throughput, latency, or the cost of a consumer group rebalance. The 300-second scale-down window remains a safety margin rather than a derived value.
- **Thresholds are still conventions.** A passing run does not calibrate the 70% target or the per-replica capacity numbers — it confirms the configured values behave as configured. Turning them into measured values needs a sustained load profile, which belongs to #277 ("define representative telemetry workloads and success thresholds") and is excluded here by #153's own Out of Scope section. [`autoscaling-strategy.md`](autoscaling-strategy.md) records the same split.
- **Single-cluster evidence.** Every recorded run is from a local single-node cluster. Scheduling behavior, metric latency, and node capacity all differ on a multi-node cluster.
- **CNI-dependent side effects are not covered.** NetworkPolicies are inert on kind and Docker Desktop (see [`network-policies/README.md`](../../infrastructure/kubernetes/network-policies/README.md)), so a run there cannot show whether a scaled-up pod is reachable under an enforcing CNI.

---

## Related Documentation

- [Autoscaling Strategy](autoscaling-strategy.md) — the targets, bounds, and the reasoning behind them
- [Kafka Topics](topics.md) — the partition count that bounds consumer scaling
- [Services](services.md) — service boundaries and responsibilities
