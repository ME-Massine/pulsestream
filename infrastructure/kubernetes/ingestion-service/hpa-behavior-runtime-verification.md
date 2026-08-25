# ingestion-service autoscaling behavior (#153)

Recorded by `scripts/validate-autoscaling-behavior.ps1` (run `ff1b41`).

| Item | Value |
| --- | --- |
| Workload | `ingestion-service` in namespace `default` |
| Tested revision | `b99b49e396f1bdd0dabf018b135ef1dfe089db01` |
| HPA bounds | `[2, 6]` at a 70% CPU target |
| Scale-down window | `300s` (read from the applied HPA) |
| Sampling | requested every `15s`, widest observed gap `55s`, gap before the scale-in recommendation `56s`, window judged with `56s` of grace (ceiling `150s`) |
| Load | 1 pod(s), 6 concurrent POST /api/v1/events loops each |
| HPA ScalingActive | `True` in all 42 samples after the first |
| HPA metrics | `cpu utilization` at 70 (desired replicas = max across metrics, tolerance `0.1`) |
| Scale-down window observed | `263s` from the first sample recommending fewer replicas (19:37:57Z: 6 replicas, cpu utilization 55/70 (6 measured) -> 5, clamped to [2, 6] -> 5) to the scale-in at 19:42:20Z |
| Peak utilization | 218% |
| Peak replicas | 6, all Ready at the peak (highest Ready count observed: 6) |
| Container restarts | 0 |
| Load-pod cleanup | Confirmed: no run-labelled pods remain |

## Timeline

```text
timestamp | cpu: current/target  min  max  replicas | ready  hpa ScalingActive
19:32:38Z | cpu:        1%/70%  2  6  2 | ready=2 scalingActive=True    <- baseline, before load
19:33:13Z | cpu:      218%/70%  2  6  4 | ready=2 scalingActive=True
19:33:32Z | cpu:      208%/70%  2  6  4 | ready=2 scalingActive=True
19:33:51Z | cpu:      190%/70%  2  6  4 | ready=2 scalingActive=True
19:34:11Z | cpu:      183%/70%  2  6  6 | ready=2 scalingActive=True
19:34:31Z | cpu:      152%/70%  2  6  6 | ready=4 scalingActive=True
19:34:49Z | cpu:      128%/70%  2  6  6 | ready=4 scalingActive=True
19:35:09Z | cpu:      111%/70%  2  6  6 | ready=5 scalingActive=True
19:35:27Z | cpu:       80%/70%  2  6  6 | ready=6 scalingActive=True
19:35:45Z | cpu:       88%/70%  2  6  6 | ready=6 scalingActive=True
19:36:04Z | cpu:      106%/70%  2  6  6 | ready=6 scalingActive=True
19:36:22Z | cpu:       95%/70%  2  6  6 | ready=6 scalingActive=True
19:36:42Z | cpu:       82%/70%  2  6  6 | ready=6 scalingActive=True
19:37:02Z | cpu:       99%/70%  2  6  6 | ready=6 scalingActive=True
19:37:57Z | cpu:       55%/70%  2  6  6 | ready=6 scalingActive=True    <- load removed
19:38:14Z | cpu:        5%/70%  2  6  6 | ready=6 scalingActive=True
19:38:31Z | cpu:        3%/70%  2  6  6 | ready=6 scalingActive=True
19:38:47Z | cpu:        3%/70%  2  6  6 | ready=6 scalingActive=True
19:39:04Z | cpu:        4%/70%  2  6  6 | ready=6 scalingActive=True
19:39:21Z | cpu:        3%/70%  2  6  6 | ready=6 scalingActive=True
19:39:38Z | cpu:        3%/70%  2  6  6 | ready=6 scalingActive=True
19:39:55Z | cpu:        3%/70%  2  6  6 | ready=6 scalingActive=True
19:40:11Z | cpu:        3%/70%  2  6  6 | ready=6 scalingActive=True
19:40:28Z | cpu:        3%/70%  2  6  6 | ready=6 scalingActive=True
19:40:45Z | cpu:        3%/70%  2  6  6 | ready=6 scalingActive=True
19:41:02Z | cpu:        3%/70%  2  6  6 | ready=6 scalingActive=True
19:41:18Z | cpu:        4%/70%  2  6  6 | ready=6 scalingActive=True
19:41:34Z | cpu:        3%/70%  2  6  6 | ready=6 scalingActive=True
19:41:50Z | cpu:        4%/70%  2  6  6 | ready=6 scalingActive=True
19:42:05Z | cpu:        2%/70%  2  6  6 | ready=6 scalingActive=True
19:42:20Z | cpu:        2%/70%  2  6  5 | ready=5 scalingActive=True
19:42:36Z | cpu:        1%/70%  2  6  5 | ready=5 scalingActive=True
19:42:51Z | cpu:        1%/70%  2  6  5 | ready=5 scalingActive=True
19:43:07Z | cpu:        1%/70%  2  6  5 | ready=5 scalingActive=True
19:43:22Z | cpu:        1%/70%  2  6  4 | ready=4 scalingActive=True
19:43:37Z | cpu:        1%/70%  2  6  4 | ready=4 scalingActive=True
19:43:52Z | cpu:        1%/70%  2  6  4 | ready=4 scalingActive=True
19:44:08Z | cpu:        1%/70%  2  6  4 | ready=4 scalingActive=True
19:44:23Z | cpu:        1%/70%  2  6  3 | ready=3 scalingActive=True
19:44:38Z | cpu:        1%/70%  2  6  3 | ready=3 scalingActive=True
19:44:54Z | cpu:        1%/70%  2  6  3 | ready=3 scalingActive=True
19:45:09Z | cpu:        0%/70%  2  6  3 | ready=3 scalingActive=True
19:45:24Z | cpu:        0%/70%  2  6  2 | ready=2 scalingActive=True
```

## Scale events

| At | Direction | Replicas |
| --- | --- | --- |
| 19:33:13Z | up | 2 -> 4 |
| 19:34:11Z | up | 4 -> 6 |
| 19:42:20Z | down | 6 -> 5 |
| 19:43:22Z | down | 5 -> 4 |
| 19:44:23Z | down | 4 -> 3 |
| 19:45:24Z | down | 3 -> 2 |

Structural assertions stay the responsibility of `scripts/validate-ingestion-hpa.ps1`.
