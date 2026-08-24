# telemetry-processor autoscaling behavior (#153)

Recorded by `scripts/validate-autoscaling-behavior.ps1` (run `f4cd67`).

| Item | Value |
| --- | --- |
| Workload | `telemetry-processor` in namespace `default` |
| Tested revision | `89e751fa32396216a11f49bfc9049e392b641a36` |
| HPA bounds | `[2, 3]` at a 70% CPU target |
| Scale-down window | `300s` (read from the applied HPA) |
| Sampling | requested every `15s`, widest observed gap `48s`, window judged with `48s` of grace |
| Load | 1 pod(s), one kafka-console-producer each into telemetry.events.raw, 900 events/s for 120s then 50 events/s per pod |
| HPA ScalingActive | `True` in all 27 samples after the first |
| HPA metrics | `cpu utilization` at 70 (desired replicas = max across metrics, tolerance `0.1`) |
| Scale-down window observed | `294s` from the first sample recommending fewer replicas (14:02:05Z: 3 replicas, cpu utilization 9/70 -> 1, clamped to [2, 3] -> 2) to the scale-in at 14:06:58Z |
| Peak utilization | 158% |
| Peak replicas | 3 |
| Container restarts | 0 |
| Load-pod cleanup | Confirmed: no run-labelled pods remain |

## Timeline

```text
timestamp | cpu: current/target  min  max  replicas | ready  hpa ScalingActive
13:59:14Z | cpu:        1%/70%  2  3  2 | ready=2 scalingActive=True    <- baseline, before load
13:59:46Z | cpu:       25%/70%  2  3  2 | ready=2 scalingActive=True
14:00:01Z | cpu:       98%/70%  2  3  3 | ready=2 scalingActive=True
14:00:16Z | cpu:       85%/70%  2  3  3 | ready=2 scalingActive=True
14:00:32Z | cpu:      115%/70%  2  3  3 | ready=3 scalingActive=True
14:00:47Z | cpu:      107%/70%  2  3  3 | ready=3 scalingActive=True
14:01:03Z | cpu:      158%/70%  2  3  3 | ready=3 scalingActive=True
14:01:18Z | cpu:      151%/70%  2  3  3 | ready=3 scalingActive=True
14:01:34Z | cpu:      118%/70%  2  3  3 | ready=3 scalingActive=True
14:01:49Z | cpu:       95%/70%  2  3  3 | ready=3 scalingActive=True
14:02:05Z | cpu:        9%/70%  2  3  3 | ready=3 scalingActive=True
14:02:20Z | cpu:       10%/70%  2  3  3 | ready=3 scalingActive=True
14:02:36Z | cpu:        8%/70%  2  3  3 | ready=3 scalingActive=True
14:02:51Z | cpu:        7%/70%  2  3  3 | ready=3 scalingActive=True
14:03:07Z | cpu:       13%/70%  2  3  3 | ready=3 scalingActive=True
14:03:23Z | cpu:       14%/70%  2  3  3 | ready=3 scalingActive=True
14:03:38Z | cpu:        9%/70%  2  3  3 | ready=3 scalingActive=True
14:04:26Z | cpu:        7%/70%  2  3  3 | ready=3 scalingActive=True    <- load removed
14:04:41Z | cpu:        1%/70%  2  3  3 | ready=3 scalingActive=True
14:04:56Z | cpu:        1%/70%  2  3  3 | ready=3 scalingActive=True
14:05:12Z | cpu:        1%/70%  2  3  3 | ready=3 scalingActive=True
14:05:27Z | cpu:        1%/70%  2  3  3 | ready=3 scalingActive=True
14:05:42Z | cpu:        1%/70%  2  3  3 | ready=3 scalingActive=True
14:05:57Z | cpu:        2%/70%  2  3  3 | ready=3 scalingActive=True
14:06:13Z | cpu:        2%/70%  2  3  3 | ready=3 scalingActive=True
14:06:28Z | cpu:        1%/70%  2  3  3 | ready=3 scalingActive=True
14:06:43Z | cpu:        1%/70%  2  3  3 | ready=3 scalingActive=True
14:06:58Z | cpu:        2%/70%  2  3  2 | ready=2 scalingActive=True
```

## Scale events

| At | Direction | Replicas |
| --- | --- | --- |
| 14:00:01Z | up | 2 -> 3 |
| 14:06:58Z | down | 3 -> 2 |

Structural assertions stay the responsibility of `scripts/validate-telemetry-processor-hpa.ps1`.
