# ingestion-service autoscaling behavior (#153)

Recorded by `scripts/validate-autoscaling-behavior.ps1` (run `0df2d4`).

| Item | Value |
| --- | --- |
| Workload | `ingestion-service` in namespace `default` |
| Tested revision | `505aa52a02e24753d5fd5695383cd86772b7d34c` |
| HPA bounds | `[2, 6]` at a 70% CPU target |
| Scale-down window | `300s` (read from the applied HPA) |
| Sampling | requested every `15s`, widest observed gap `56s`, gap before the scale-in recommendation `18s`, window judged with `30s` of grace (ceiling `150s`) |
| Load | 1 pod(s), 8 concurrent POST /api/v1/events loops each |
| HPA ScalingActive | `True` in all 42 samples after the first |
| HPA metrics | `cpu utilization` at 70 (desired replicas = max across metrics, tolerance `0.1`) |
| Scale-down window observed | `290s` from the first sample recommending fewer replicas (14:36:18Z: 6 replicas (6 of them measured), cpu utilization 58/70 -> 5, clamped to [2, 6] -> 5) to the scale-in at 14:41:08Z |
| Peak utilization | 319% |
| Peak replicas | 6, all Ready at the peak (highest Ready count observed: 6) |
| Container restarts | 0 |
| Load-pod cleanup | Confirmed: no run-labelled pods remain |

## Timeline

```text
timestamp | cpu: current/target  min  max  replicas | ready  hpa ScalingActive
14:30:52Z | cpu:        3%/70%  2  6  2 | ready=2 scalingActive=True    <- baseline, before load
14:31:24Z | cpu:       41%/70%  2  6  2 | ready=2 scalingActive=True
14:31:41Z | cpu:      312%/70%  2  6  4 | ready=2 scalingActive=True
14:31:57Z | cpu:      319%/70%  2  6  4 | ready=2 scalingActive=True
14:32:13Z | cpu:      143%/70%  2  6  4 | ready=4 scalingActive=True
14:32:30Z | cpu:       80%/70%  2  6  4 | ready=4 scalingActive=True
14:32:46Z | cpu:       81%/70%  2  6  6 | ready=4 scalingActive=True
14:33:03Z | cpu:      128%/70%  2  6  6 | ready=4 scalingActive=True
14:33:21Z | cpu:       89%/70%  2  6  6 | ready=4 scalingActive=True
14:33:41Z | cpu:      124%/70%  2  6  6 | ready=6 scalingActive=True
14:34:05Z | cpu:       68%/70%  2  6  6 | ready=6 scalingActive=True
14:34:23Z | cpu:       27%/70%  2  6  6 | ready=6 scalingActive=True
14:34:43Z | cpu:       27%/70%  2  6  6 | ready=6 scalingActive=True
14:35:05Z | cpu:      187%/70%  2  6  6 | ready=6 scalingActive=True
14:36:00Z | cpu:      175%/70%  2  6  6 | ready=6 scalingActive=True    <- load removed
14:36:18Z | cpu:       58%/70%  2  6  6 | ready=6 scalingActive=True
14:36:35Z | cpu:       11%/70%  2  6  6 | ready=6 scalingActive=True
14:36:53Z | cpu:       16%/70%  2  6  6 | ready=6 scalingActive=True
14:37:10Z | cpu:        6%/70%  2  6  6 | ready=6 scalingActive=True
14:37:27Z | cpu:       10%/70%  2  6  6 | ready=6 scalingActive=True
14:37:44Z | cpu:        9%/70%  2  6  6 | ready=6 scalingActive=True
14:38:02Z | cpu:        7%/70%  2  6  6 | ready=6 scalingActive=True
14:38:19Z | cpu:        4%/70%  2  6  6 | ready=6 scalingActive=True
14:38:36Z | cpu:        5%/70%  2  6  6 | ready=6 scalingActive=True
14:38:53Z | cpu:        8%/70%  2  6  6 | ready=6 scalingActive=True
14:39:10Z | cpu:        5%/70%  2  6  6 | ready=6 scalingActive=True
14:39:26Z | cpu:        4%/70%  2  6  6 | ready=6 scalingActive=True
14:39:44Z | cpu:        6%/70%  2  6  6 | ready=6 scalingActive=True
14:40:01Z | cpu:       20%/70%  2  6  6 | ready=6 scalingActive=True
14:40:18Z | cpu:        5%/70%  2  6  6 | ready=6 scalingActive=True
14:40:34Z | cpu:        6%/70%  2  6  6 | ready=6 scalingActive=True
14:40:50Z | cpu:        5%/70%  2  6  6 | ready=6 scalingActive=True
14:41:08Z | cpu:       13%/70%  2  6  5 | ready=5 scalingActive=True
14:41:24Z | cpu:        6%/70%  2  6  5 | ready=5 scalingActive=True
14:41:40Z | cpu:        6%/70%  2  6  5 | ready=5 scalingActive=True
14:41:57Z | cpu:        6%/70%  2  6  4 | ready=4 scalingActive=True
14:42:13Z | cpu:        6%/70%  2  6  4 | ready=4 scalingActive=True
14:42:30Z | cpu:        4%/70%  2  6  4 | ready=4 scalingActive=True
14:42:47Z | cpu:        5%/70%  2  6  4 | ready=4 scalingActive=True
14:43:04Z | cpu:        8%/70%  2  6  3 | ready=3 scalingActive=True
14:43:21Z | cpu:        6%/70%  2  6  3 | ready=3 scalingActive=True
14:43:37Z | cpu:        6%/70%  2  6  3 | ready=3 scalingActive=True
14:43:55Z | cpu:       15%/70%  2  6  2 | ready=2 scalingActive=True
```

## Scale events

| At | Direction | Replicas |
| --- | --- | --- |
| 14:31:41Z | up | 2 -> 4 |
| 14:32:46Z | up | 4 -> 6 |
| 14:41:08Z | down | 6 -> 5 |
| 14:41:57Z | down | 5 -> 4 |
| 14:43:04Z | down | 4 -> 3 |
| 14:43:55Z | down | 3 -> 2 |

Structural assertions stay the responsibility of `scripts/validate-ingestion-hpa.ps1`.
