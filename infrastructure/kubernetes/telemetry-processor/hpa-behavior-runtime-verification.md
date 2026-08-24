# telemetry-processor autoscaling behavior (#153)

Recorded by `scripts/validate-autoscaling-behavior.ps1` (run `61bf0d`).

| Item | Value |
| --- | --- |
| Workload | `telemetry-processor` in namespace `default` |
| Tested revision | `adac0572dfe11401583cd16de48e9dcbffb1bf4c`; working-tree changes were generated evidence reports only |
| HPA bounds | `[2, 3]` at a 70% CPU target |
| Scale-down window | `300s` (read from the applied HPA) |
| Sampling | requested every `15s`, widest observed gap `47s`, window judged with `47s` of grace |
| Load | 1 pod(s), one kafka-console-producer each into telemetry.events.raw, 350 events/s for 45s then 50 events/s per pod |
| HPA ScalingActive | `True` in all 20 samples after the first |
| Peak utilization | 135% |
| Peak replicas | 3 |
| Container restarts | 0 |
| Load-pod cleanup | Confirmed: no run-labelled pods remain |

## Timeline

```text
timestamp | cpu: current/target  min  max  replicas | ready  hpa ScalingActive
01:51:30Z | cpu:        4%/70%  2  3  2 | ready=2 scalingActive=True    <- baseline, before load
01:52:02Z | cpu:      135%/70%  2  3  3 | ready=2 scalingActive=True
01:52:17Z | cpu:       73%/70%  2  3  3 | ready=2 scalingActive=True
01:52:33Z | cpu:       58%/70%  2  3  3 | ready=3 scalingActive=True
01:52:48Z | cpu:       20%/70%  2  3  3 | ready=3 scalingActive=True
01:53:04Z | cpu:       12%/70%  2  3  3 | ready=3 scalingActive=True
01:53:19Z | cpu:       11%/70%  2  3  3 | ready=3 scalingActive=True
01:53:34Z | cpu:       11%/70%  2  3  3 | ready=3 scalingActive=True
01:53:50Z | cpu:        9%/70%  2  3  3 | ready=3 scalingActive=True
01:54:05Z | cpu:       12%/70%  2  3  3 | ready=3 scalingActive=True
01:54:21Z | cpu:       10%/70%  2  3  3 | ready=3 scalingActive=True
01:54:36Z | cpu:        9%/70%  2  3  3 | ready=3 scalingActive=True
01:54:51Z | cpu:        9%/70%  2  3  3 | ready=3 scalingActive=True
01:55:07Z | cpu:       12%/70%  2  3  3 | ready=3 scalingActive=True
01:55:22Z | cpu:        9%/70%  2  3  3 | ready=3 scalingActive=True
01:55:38Z | cpu:        9%/70%  2  3  3 | ready=3 scalingActive=True
01:55:53Z | cpu:        8%/70%  2  3  3 | ready=3 scalingActive=True
01:56:40Z | cpu:        8%/70%  2  3  3 | ready=3 scalingActive=True    <- load removed
01:56:55Z | cpu:        5%/70%  2  3  3 | ready=3 scalingActive=True
01:57:10Z | cpu:        2%/70%  2  3  3 | ready=3 scalingActive=True
01:57:26Z | cpu:        2%/70%  2  3  2 | ready=2 scalingActive=True
```

## Scale events

| At | Direction | Replicas |
| --- | --- | --- |
| 01:52:02Z | up | 2 -> 3 |
| 01:57:26Z | down | 3 -> 2 |

Structural assertions stay the responsibility of `scripts/validate-telemetry-processor-hpa.ps1`.
