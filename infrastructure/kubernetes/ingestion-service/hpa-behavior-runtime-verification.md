# ingestion-service autoscaling behavior (#153)

Recorded by `scripts/validate-autoscaling-behavior.ps1` (run `fb876e`).

| Item | Value |
| --- | --- |
| Workload | `ingestion-service` in namespace `default` |
| Tested revision | `adac0572dfe11401583cd16de48e9dcbffb1bf4c`; working-tree changes were generated evidence reports only |
| HPA bounds | `[2, 6]` at a 70% CPU target |
| Scale-down window | `300s` (read from the applied HPA) |
| Sampling | requested every `15s`, widest observed gap `47s`, window judged with `47s` of grace |
| Load | 1 pod(s), 16 concurrent POST /api/v1/events loops each |
| HPA ScalingActive | `True` in all 43 samples after the first |
| Peak utilization | 260% |
| Peak replicas | 6 |
| Container restarts | 0 |
| Load-pod cleanup | Confirmed: no run-labelled pods remain |

## Timeline

```text
timestamp | cpu: current/target  min  max  replicas | ready  hpa ScalingActive
01:58:33Z | cpu:        1%/70%  2  6  2 | ready=2 scalingActive=True    <- baseline, before load
01:59:05Z | cpu:      185%/70%  2  6  4 | ready=2 scalingActive=True
01:59:20Z | cpu:      260%/70%  2  6  4 | ready=2 scalingActive=True
01:59:36Z | cpu:      244%/70%  2  6  4 | ready=4 scalingActive=True
01:59:51Z | cpu:      145%/70%  2  6  4 | ready=4 scalingActive=True
02:00:07Z | cpu:      123%/70%  2  6  6 | ready=4 scalingActive=True
02:00:22Z | cpu:      110%/70%  2  6  6 | ready=6 scalingActive=True
02:00:38Z | cpu:       77%/70%  2  6  6 | ready=6 scalingActive=True
02:00:54Z | cpu:       99%/70%  2  6  6 | ready=6 scalingActive=True
02:01:09Z | cpu:       97%/70%  2  6  6 | ready=6 scalingActive=True
02:01:25Z | cpu:       71%/70%  2  6  6 | ready=6 scalingActive=True
02:01:40Z | cpu:       70%/70%  2  6  6 | ready=6 scalingActive=True
02:01:56Z | cpu:       61%/70%  2  6  6 | ready=6 scalingActive=True
02:02:11Z | cpu:       62%/70%  2  6  6 | ready=6 scalingActive=True
02:02:27Z | cpu:       70%/70%  2  6  6 | ready=6 scalingActive=True
02:02:42Z | cpu:       55%/70%  2  6  6 | ready=6 scalingActive=True
02:02:58Z | cpu:       45%/70%  2  6  6 | ready=6 scalingActive=True
02:03:45Z | cpu:       38%/70%  2  6  6 | ready=6 scalingActive=True    <- load removed
02:04:00Z | cpu:       33%/70%  2  6  6 | ready=6 scalingActive=True
02:04:15Z | cpu:        3%/70%  2  6  6 | ready=6 scalingActive=True
02:04:30Z | cpu:        0%/70%  2  6  6 | ready=6 scalingActive=True
02:04:46Z | cpu:        0%/70%  2  6  6 | ready=6 scalingActive=True
02:05:01Z | cpu:        0%/70%  2  6  6 | ready=6 scalingActive=True
02:05:16Z | cpu:        0%/70%  2  6  6 | ready=6 scalingActive=True
02:05:32Z | cpu:        0%/70%  2  6  6 | ready=6 scalingActive=True
02:05:47Z | cpu:        1%/70%  2  6  6 | ready=6 scalingActive=True
02:06:02Z | cpu:        1%/70%  2  6  6 | ready=6 scalingActive=True
02:06:18Z | cpu:        0%/70%  2  6  6 | ready=6 scalingActive=True
02:06:33Z | cpu:        0%/70%  2  6  6 | ready=6 scalingActive=True
02:06:48Z | cpu:        1%/70%  2  6  6 | ready=6 scalingActive=True
02:07:04Z | cpu:        1%/70%  2  6  6 | ready=6 scalingActive=True
02:07:19Z | cpu:        0%/70%  2  6  5 | ready=5 scalingActive=True
02:07:34Z | cpu:        0%/70%  2  6  5 | ready=5 scalingActive=True
02:07:49Z | cpu:        0%/70%  2  6  5 | ready=5 scalingActive=True
02:08:05Z | cpu:        1%/70%  2  6  5 | ready=5 scalingActive=True
02:08:20Z | cpu:        1%/70%  2  6  4 | ready=4 scalingActive=True
02:08:35Z | cpu:        1%/70%  2  6  4 | ready=4 scalingActive=True
02:08:51Z | cpu:        0%/70%  2  6  4 | ready=4 scalingActive=True
02:09:06Z | cpu:        1%/70%  2  6  4 | ready=4 scalingActive=True
02:09:21Z | cpu:        1%/70%  2  6  3 | ready=3 scalingActive=True
02:09:37Z | cpu:        1%/70%  2  6  3 | ready=3 scalingActive=True
02:09:52Z | cpu:        0%/70%  2  6  3 | ready=3 scalingActive=True
02:10:07Z | cpu:        1%/70%  2  6  3 | ready=3 scalingActive=True
02:10:23Z | cpu:        1%/70%  2  6  2 | ready=2 scalingActive=True
```

## Scale events

| At | Direction | Replicas |
| --- | --- | --- |
| 01:59:05Z | up | 2 -> 4 |
| 02:00:07Z | up | 4 -> 6 |
| 02:07:19Z | down | 6 -> 5 |
| 02:08:20Z | down | 5 -> 4 |
| 02:09:21Z | down | 4 -> 3 |
| 02:10:23Z | down | 3 -> 2 |

Structural assertions stay the responsibility of `scripts/validate-ingestion-hpa.ps1`.
