# telemetry-processor autoscaling behavior (#153)

Recorded by `scripts/validate-autoscaling-behavior.ps1` (run `77b879`).

| Item | Value |
| --- | --- |
| Workload | `telemetry-processor` in namespace `default` |
| Tested revision | `b99b49e396f1bdd0dabf018b135ef1dfe089db01` |
| HPA bounds | `[2, 3]` at a 70% CPU target |
| Scale-down window | `300s` (read from the applied HPA) |
| Sampling | requested every `15s`, widest observed gap `47s`, gap before the scale-in recommendation `29s`, window judged with `30s` of grace (ceiling `150s`) |
| Load | 1 pod(s), one kafka-console-producer each into telemetry.events.raw, 500 events/s for 45s then 50 events/s per pod |
| HPA ScalingActive | `True` in all 23 samples after the first |
| HPA metrics | `cpu utilization` at 70 (desired replicas = max across metrics, tolerance `0.1`) |
| Scale-down window observed | `289s` from the first sample recommending fewer replicas (20:24:05Z: 3 replicas, cpu utilization 20/70 (3 measured) -> 1, clamped to [2, 3] -> 2) to the scale-in at 20:28:54Z |
| Peak utilization | 166% |
| Peak replicas | 3, all Ready at the peak (highest Ready count observed: 3) |
| Container restarts | 0 |
| Load-pod cleanup | Confirmed: no run-labelled pods remain |

## Timeline

```text
timestamp | cpu: current/target  min  max  replicas | ready  hpa ScalingActive
20:21:42Z | cpu:        4%/70%  2  3  2 | ready=2 scalingActive=True    <- baseline, before load
20:22:14Z | cpu:      115%/70%  2  3  3 | ready=2 scalingActive=True
20:22:30Z | cpu:      138%/70%  2  3  3 | ready=2 scalingActive=True
20:22:46Z | cpu:      166%/70%  2  3  3 | ready=2 scalingActive=True
20:23:02Z | cpu:       84%/70%  2  3  3 | ready=3 scalingActive=True
20:23:18Z | cpu:       18%/70%  2  3  3 | ready=3 scalingActive=True
20:23:36Z | cpu:       85%/70%  2  3  3 | ready=3 scalingActive=True
20:24:05Z | cpu:       20%/70%  2  3  3 | ready=3 scalingActive=True
20:24:22Z | cpu:       24%/70%  2  3  3 | ready=3 scalingActive=True
20:24:39Z | cpu:       25%/70%  2  3  3 | ready=3 scalingActive=True
20:24:57Z | cpu:       18%/70%  2  3  3 | ready=3 scalingActive=True
20:25:14Z | cpu:       18%/70%  2  3  3 | ready=3 scalingActive=True
20:25:31Z | cpu:       26%/70%  2  3  3 | ready=3 scalingActive=True
20:25:47Z | cpu:       19%/70%  2  3  3 | ready=3 scalingActive=True
20:26:03Z | cpu:       15%/70%  2  3  3 | ready=3 scalingActive=True
20:26:50Z | cpu:       14%/70%  2  3  3 | ready=3 scalingActive=True    <- load removed
20:27:06Z | cpu:        3%/70%  2  3  3 | ready=3 scalingActive=True
20:27:21Z | cpu:        2%/70%  2  3  3 | ready=3 scalingActive=True
20:27:37Z | cpu:        3%/70%  2  3  3 | ready=3 scalingActive=True
20:27:52Z | cpu:        2%/70%  2  3  3 | ready=3 scalingActive=True
20:28:08Z | cpu:        2%/70%  2  3  3 | ready=3 scalingActive=True
20:28:23Z | cpu:        2%/70%  2  3  3 | ready=3 scalingActive=True
20:28:38Z | cpu:        2%/70%  2  3  3 | ready=3 scalingActive=True
20:28:54Z | cpu:        2%/70%  2  3  2 | ready=2 scalingActive=True
```

## Scale events

| At | Direction | Replicas |
| --- | --- | --- |
| 20:22:14Z | up | 2 -> 3 |
| 20:28:54Z | down | 3 -> 2 |

Structural assertions stay the responsibility of `scripts/validate-telemetry-processor-hpa.ps1`.
