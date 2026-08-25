# telemetry-processor autoscaling behavior (#153)

Recorded by `scripts/validate-autoscaling-behavior.ps1` (run `0ecdac`).

| Item | Value |
| --- | --- |
| Workload | `telemetry-processor` in namespace `default` |
| Tested revision | `505aa52a02e24753d5fd5695383cd86772b7d34c` |
| HPA bounds | `[2, 3]` at a 70% CPU target |
| Scale-down window | `300s` (read from the applied HPA) |
| Sampling | requested every `15s`, widest observed gap `47s`, gap before the scale-in recommendation `16s`, window judged with `30s` of grace (ceiling `150s`) |
| Load | 1 pod(s), one kafka-console-producer each into telemetry.events.raw, 900 events/s for 45s then 50 events/s per pod |
| HPA ScalingActive | `True` in all 21 samples after the first |
| HPA metrics | `cpu utilization` at 70 (desired replicas = max across metrics, tolerance `0.1`) |
| Scale-down window observed | `283s` from the first sample recommending fewer replicas (14:54:49Z: 3 replicas (3 of them measured), cpu utilization 38/70 -> 2, clamped to [2, 3] -> 2) to the scale-in at 14:59:33Z |
| Peak utilization | 275% |
| Peak replicas | 3, all Ready at the peak (highest Ready count observed: 3) |
| Container restarts | 0 |
| Load-pod cleanup | Confirmed: no run-labelled pods remain |

## Timeline

```text
timestamp | cpu: current/target  min  max  replicas | ready  hpa ScalingActive
14:53:16Z | cpu:        3%/70%  2  3  2 | ready=2 scalingActive=True    <- baseline, before load
14:53:47Z | cpu:      220%/70%  2  3  3 | ready=2 scalingActive=True
14:54:03Z | cpu:      275%/70%  2  3  3 | ready=2 scalingActive=True
14:54:18Z | cpu:      198%/70%  2  3  3 | ready=3 scalingActive=True
14:54:34Z | cpu:      125%/70%  2  3  3 | ready=3 scalingActive=True
14:54:49Z | cpu:       38%/70%  2  3  3 | ready=3 scalingActive=True
14:55:05Z | cpu:       26%/70%  2  3  3 | ready=3 scalingActive=True
14:55:20Z | cpu:       10%/70%  2  3  3 | ready=3 scalingActive=True
14:55:35Z | cpu:       11%/70%  2  3  3 | ready=3 scalingActive=True
14:55:51Z | cpu:        8%/70%  2  3  3 | ready=3 scalingActive=True
14:56:06Z | cpu:       10%/70%  2  3  3 | ready=3 scalingActive=True
14:56:21Z | cpu:        9%/70%  2  3  3 | ready=3 scalingActive=True
14:56:37Z | cpu:       10%/70%  2  3  3 | ready=3 scalingActive=True
14:56:52Z | cpu:        9%/70%  2  3  3 | ready=3 scalingActive=True
14:57:08Z | cpu:       12%/70%  2  3  3 | ready=3 scalingActive=True
14:57:23Z | cpu:       10%/70%  2  3  3 | ready=3 scalingActive=True
14:57:38Z | cpu:        8%/70%  2  3  3 | ready=3 scalingActive=True
14:58:25Z | cpu:        6%/70%  2  3  3 | ready=3 scalingActive=True    <- load removed
14:58:40Z | cpu:        2%/70%  2  3  3 | ready=3 scalingActive=True
14:58:59Z | cpu:        1%/70%  2  3  3 | ready=3 scalingActive=True
14:59:17Z | cpu:        3%/70%  2  3  3 | ready=3 scalingActive=True
14:59:33Z | cpu:        7%/70%  2  3  2 | ready=2 scalingActive=True
```

## Scale events

| At | Direction | Replicas |
| --- | --- | --- |
| 14:53:47Z | up | 2 -> 3 |
| 14:59:33Z | down | 3 -> 2 |

Structural assertions stay the responsibility of `scripts/validate-telemetry-processor-hpa.ps1`.
