# ingestion-service autoscaling behavior (#153)

Recorded by `scripts/validate-autoscaling-behavior.ps1` (run `06147a`).

| Item | Value |
| --- | --- |
| Workload | `ingestion-service` in namespace `default` |
| Tested revision | `89e751fa32396216a11f49bfc9049e392b641a36` |
| HPA bounds | `[2, 6]` at a 70% CPU target |
| Scale-down window | `300s` (read from the applied HPA) |
| Sampling | requested every `15s`, widest observed gap `58s`, window judged with `59s` of grace |
| Load | 1 pod(s), 8 concurrent POST /api/v1/events loops each |
| HPA ScalingActive | `True` in all 34 samples after the first |
| HPA metrics | `cpu utilization` at 70 (desired replicas = max across metrics, tolerance `0.1`) |
| Scale-down window observed | `274s` from the first sample recommending fewer replicas (13:42:06Z: 4 replicas, cpu utilization 50/70 -> 3, clamped to [2, 6] -> 3) to the scale-in at 13:46:40Z |
| Peak utilization | 107% |
| Peak replicas | 4 |
| Container restarts | 0 |
| Load-pod cleanup | Confirmed: no run-labelled pods remain |

## Timeline

```text
timestamp | cpu: current/target  min  max  replicas | ready  hpa ScalingActive
13:37:52Z | cpu:        0%/70%  2  6  2 | ready=2 scalingActive=True    <- baseline, before load
13:38:23Z | cpu:      107%/70%  2  6  4 | ready=2 scalingActive=True
13:38:39Z | cpu:       90%/70%  2  6  4 | ready=2 scalingActive=True
13:38:54Z | cpu:       80%/70%  2  6  4 | ready=3 scalingActive=True
13:39:10Z | cpu:       50%/70%  2  6  4 | ready=3 scalingActive=True
13:39:26Z | cpu:       85%/70%  2  6  4 | ready=3 scalingActive=True
13:39:42Z | cpu:       82%/70%  2  6  4 | ready=3 scalingActive=True
13:39:58Z | cpu:       73%/70%  2  6  4 | ready=3 scalingActive=True
13:40:14Z | cpu:       46%/70%  2  6  4 | ready=3 scalingActive=True
13:40:30Z | cpu:       41%/70%  2  6  4 | ready=3 scalingActive=True
13:40:47Z | cpu:       27%/70%  2  6  4 | ready=3 scalingActive=True
13:41:02Z | cpu:       33%/70%  2  6  4 | ready=3 scalingActive=True
13:41:18Z | cpu:       34%/70%  2  6  4 | ready=3 scalingActive=True
13:41:34Z | cpu:       96%/70%  2  6  4 | ready=3 scalingActive=True
13:41:50Z | cpu:       58%/70%  2  6  4 | ready=3 scalingActive=True
13:42:06Z | cpu:       50%/70%  2  6  4 | ready=3 scalingActive=True
13:43:04Z | cpu:       36%/70%  2  6  4 | ready=3 scalingActive=True    <- load removed
13:43:19Z | cpu:       21%/70%  2  6  4 | ready=3 scalingActive=True
13:43:35Z | cpu:        3%/70%  2  6  4 | ready=3 scalingActive=True
13:43:50Z | cpu:        2%/70%  2  6  4 | ready=3 scalingActive=True
13:44:06Z | cpu:        2%/70%  2  6  4 | ready=3 scalingActive=True
13:44:21Z | cpu:        2%/70%  2  6  4 | ready=3 scalingActive=True
13:44:36Z | cpu:        2%/70%  2  6  4 | ready=3 scalingActive=True
13:44:52Z | cpu:        1%/70%  2  6  4 | ready=3 scalingActive=True
13:45:07Z | cpu:        1%/70%  2  6  4 | ready=3 scalingActive=True
13:45:23Z | cpu:        2%/70%  2  6  4 | ready=3 scalingActive=True
13:45:38Z | cpu:        1%/70%  2  6  4 | ready=3 scalingActive=True
13:45:54Z | cpu:        1%/70%  2  6  4 | ready=3 scalingActive=True
13:46:09Z | cpu:        1%/70%  2  6  4 | ready=3 scalingActive=True
13:46:24Z | cpu:        1%/70%  2  6  4 | ready=3 scalingActive=True
13:46:40Z | cpu:        2%/70%  2  6  3 | ready=3 scalingActive=True
13:46:56Z | cpu:        1%/70%  2  6  3 | ready=3 scalingActive=True
13:47:11Z | cpu:        2%/70%  2  6  3 | ready=3 scalingActive=True
13:47:27Z | cpu:        2%/70%  2  6  3 | ready=3 scalingActive=True
13:47:42Z | cpu:        1%/70%  2  6  2 | ready=2 scalingActive=True
```

## Scale events

| At | Direction | Replicas |
| --- | --- | --- |
| 13:38:23Z | up | 2 -> 4 |
| 13:46:40Z | down | 4 -> 3 |
| 13:47:42Z | down | 3 -> 2 |

Structural assertions stay the responsibility of `scripts/validate-ingestion-hpa.ps1`.
