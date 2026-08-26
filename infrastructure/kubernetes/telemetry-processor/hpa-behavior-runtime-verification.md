# telemetry-processor autoscaling behavior (#153)

Recorded by `scripts/validate-autoscaling-behavior.ps1` (run `7f6088`).

| Item | Value |
| --- | --- |
| Workload | `telemetry-processor` in namespace `default` |
| Tested revision | `94213047802debcbb8ee5e3ed2081174dc1e1034` |
| HPA bounds | `[2, 3]` at a 70% CPU target |
| Scale-down window | `300s` (read from the applied HPA) |
| Sampling | requested every `10s`, widest observed gap `43s`, gap before the scale-in recommendation `12s`, window judged with `30s` of fixed grace (ceiling `150s`; observed gaps shrink the proven bound instead of widening the grace; consecutive samples more than `60s` apart stop counting as continuous observation) |
| Load | 1 pod(s), one kafka-console-producer each into telemetry.events.raw, 150 events/s for 90s then 60 events/s per pod |
| HPA ScalingActive | `True` in all 34 samples after the first (health signal only; attribution is per scale event below) |
| HPA rescale attribution | 2 of 2 replica transitions correlated with the HPA's desiredReplicas and an advancing lastScaleTime |
| HPA metrics | `cpu utilization` at 70 (desired replicas = max across metrics, tolerance `0.1`) |
| Scale-down window | proven recommendation duration `>= 277s`: recommended continuously from 14:01:58Z (3 replicas, cpu utilization 37/70 (3 measured) -> 2, clamped to [2, 3] -> 2) through the last old-count sample at 14:06:36Z; decision observed at 14:06:47Z (anchor-to-observation spacing `289s`, recommendation turnover uncertain by the `12s` gap ending at the anchor). |
| Peak utilization | 358% |
| Peak replicas | 3, all Ready at the peak (highest Ready count observed: 3) |
| Container restarts | 0 |
| Load-pod cleanup | Confirmed: no run-labelled pods remain |

## Timeline

```text
timestamp | cpu: current/target  min  max  replicas | scale-subresource desired  HPA desired  HPA lastScaleTime  ready  hpa ScalingActive
13:59:29Z | cpu:        6%/70%  2  3  2 | desired=2 hpaDesired=2 lastScale=13:55:41Z ready=2 scalingActive=True    <- baseline, before load
13:59:53Z | cpu:        7%/70%  2  3  2 | desired=2 hpaDesired=2 lastScale=13:55:41Z ready=2 scalingActive=True
14:00:06Z | cpu:        6%/70%  2  3  2 | desired=2 hpaDesired=2 lastScale=13:55:41Z ready=2 scalingActive=True
14:00:20Z | cpu:      227%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=2 scalingActive=True
14:00:33Z | cpu:      358%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=2 scalingActive=True
14:00:46Z | cpu:      285%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=2 scalingActive=True
14:00:59Z | cpu:      195%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=2 scalingActive=True
14:01:12Z | cpu:      160%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=2 scalingActive=True
14:01:24Z | cpu:      160%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:01:36Z | cpu:      166%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:01:47Z | cpu:      166%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:01:58Z | cpu:       37%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:02:10Z | cpu:       37%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:02:22Z | cpu:       44%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:02:33Z | cpu:       32%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:02:45Z | cpu:       26%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:02:56Z | cpu:       26%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:03:07Z | cpu:       30%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:03:19Z | cpu:       28%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:03:30Z | cpu:       32%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:03:41Z | cpu:       34%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:04:24Z | cpu:       25%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True    <- load removed
14:04:35Z | cpu:       22%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:04:46Z | cpu:       22%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:04:57Z | cpu:        4%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:05:08Z | cpu:        4%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:05:19Z | cpu:        3%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:05:30Z | cpu:        3%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:05:41Z | cpu:        3%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:05:52Z | cpu:        3%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:06:03Z | cpu:        3%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:06:14Z | cpu:        3%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:06:25Z | cpu:        3%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:06:36Z | cpu:        3%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=14:00:11Z ready=3 scalingActive=True
14:06:47Z | cpu:        3%/70%  2  3  2 | desired=2 hpaDesired=2 lastScale=14:06:42Z ready=2 scalingActive=True
```

## Scale events

`desired` in the timeline is the scale subresource's requested count, which is where the HPA writes its decision; `replicas`/`ready` are what the workload realized, and can lag it. Each event below is timestamped from the first sampled transition of the desired count, and is credited to the HPA only on the controller's own rescale evidence.

| Decision observed | Direction | Desired replicas | Decision source | HPA rescale evidence |
| --- | --- | --- | --- | --- |
| 14:00:20Z | up | 2 -> 3 | scale subresource | HPA desiredReplicas=3 with lastScaleTime advanced to 14:00:11Z, read at the 14:00:20Z sample (AbleToScale: SucceededRescale) |
| 14:06:47Z | down | 3 -> 2 | scale subresource | HPA desiredReplicas=2 with lastScaleTime advanced to 14:06:42Z, read at the 14:06:47Z sample (AbleToScale: SucceededRescale) |

Structural assertions stay the responsibility of `scripts/validate-telemetry-processor-hpa.ps1`.
