# ingestion-service autoscaling behavior (#153)

Recorded by `scripts/validate-autoscaling-behavior.ps1` (run `f897bf`).

| Item | Value |
| --- | --- |
| Workload | `ingestion-service` in namespace `default` |
| Tested revision | `94213047802debcbb8ee5e3ed2081174dc1e1034` |
| HPA bounds | `[2, 6]` at a 70% CPU target |
| Scale-down window | `300s` (read from the applied HPA) |
| Sampling | requested every `15s`, widest observed gap `57s`, gap before the scale-in recommendation `17s`, window judged with `30s` of fixed grace (ceiling `150s`; observed gaps shrink the proven bound instead of widening the grace; consecutive samples more than `60s` apart stop counting as continuous observation) |
| Load | 1 pod(s), 6 concurrent POST /api/v1/events loops each |
| HPA ScalingActive | `True` in all 45 samples after the first (health signal only; attribution is per scale event below) |
| HPA rescale attribution | 6 of 6 replica transitions correlated with the HPA's desiredReplicas and an advancing lastScaleTime |
| HPA metrics | `cpu utilization` at 70 (desired replicas = max across metrics, tolerance `0.1`) |
| Scale-down window | proven recommendation duration `>= 270s`: recommended continuously from 13:09:02Z (6 replicas, cpu utilization 4/70 (6 measured) -> 1, clamped to [2, 6] -> 2) through the last old-count sample at 13:13:33Z; decision observed at 13:13:49Z (anchor-to-observation spacing `287s`, recommendation turnover uncertain by the `17s` gap ending at the anchor). |
| Peak utilization | 263% |
| Peak replicas | 6, all Ready at the peak (highest Ready count observed: 6) |
| Container restarts | 0 |
| Load-pod cleanup | Confirmed: no run-labelled pods remain |

## Timeline

```text
timestamp | cpu: current/target  min  max  replicas | scale-subresource desired  HPA desired  HPA lastScaleTime  ready  hpa ScalingActive
13:03:01Z | cpu:        5%/70%  2  6  2 | desired=2 hpaDesired=2 lastScale=02:39:31Z ready=2 scalingActive=True    <- baseline, before load
13:03:35Z | cpu:      263%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=13:03:33Z ready=2 scalingActive=True
13:03:55Z | cpu:      214%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=13:03:33Z ready=2 scalingActive=True
13:04:13Z | cpu:      230%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=13:03:33Z ready=4 scalingActive=True
13:04:32Z | cpu:      162%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=13:03:33Z ready=4 scalingActive=True
13:04:50Z | cpu:      148%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=4 scalingActive=True
13:05:09Z | cpu:      133%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:05:28Z | cpu:      111%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:05:48Z | cpu:      110%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:06:15Z | cpu:      118%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:06:31Z | cpu:      105%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:06:53Z | cpu:      130%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:07:13Z | cpu:       64%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:07:32Z | cpu:       85%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:08:29Z | cpu:      164%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True    <- load removed
13:08:46Z | cpu:       68%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:09:02Z | cpu:        4%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:09:18Z | cpu:        2%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:09:34Z | cpu:        2%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:09:50Z | cpu:        2%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:10:07Z | cpu:        2%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:10:23Z | cpu:        3%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:10:39Z | cpu:        2%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:10:55Z | cpu:        2%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:11:10Z | cpu:        2%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:11:26Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:11:42Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:11:58Z | cpu:        2%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:12:14Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:12:30Z | cpu:        3%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:12:45Z | cpu:        2%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:13:01Z | cpu:        2%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:13:17Z | cpu:        3%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:13:33Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:04:33Z ready=6 scalingActive=True
13:13:49Z | cpu:        2%/70%  2  6  5 | desired=5 hpaDesired=5 lastScale=13:13:36Z ready=5 scalingActive=True
13:14:05Z | cpu:        2%/70%  2  6  5 | desired=5 hpaDesired=5 lastScale=13:13:36Z ready=5 scalingActive=True
13:14:20Z | cpu:        3%/70%  2  6  5 | desired=5 hpaDesired=5 lastScale=13:13:36Z ready=5 scalingActive=True
13:14:36Z | cpu:        1%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=13:14:36Z ready=4 scalingActive=True
13:14:52Z | cpu:        1%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=13:14:36Z ready=4 scalingActive=True
13:15:08Z | cpu:        2%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=13:14:36Z ready=4 scalingActive=True
13:15:24Z | cpu:        1%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=13:14:36Z ready=4 scalingActive=True
13:15:39Z | cpu:        2%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=13:15:36Z ready=3 scalingActive=True
13:15:55Z | cpu:        1%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=13:15:36Z ready=3 scalingActive=True
13:16:11Z | cpu:        2%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=13:15:36Z ready=3 scalingActive=True
13:16:27Z | cpu:        2%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=13:15:36Z ready=3 scalingActive=True
13:16:42Z | cpu:        2%/70%  2  6  2 | desired=2 hpaDesired=2 lastScale=13:16:36Z ready=2 scalingActive=True
```

## Scale events

`desired` in the timeline is the scale subresource's requested count, which is where the HPA writes its decision; `replicas`/`ready` are what the workload realized, and can lag it. Each event below is timestamped from the first sampled transition of the desired count, and is credited to the HPA only on the controller's own rescale evidence.

| Decision observed | Direction | Desired replicas | Decision source | HPA rescale evidence |
| --- | --- | --- | --- | --- |
| 13:03:35Z | up | 2 -> 4 | scale subresource | HPA desiredReplicas=4 with lastScaleTime advanced to 13:03:33Z, read at the 13:03:35Z sample (AbleToScale: SucceededRescale) |
| 13:04:50Z | up | 4 -> 6 | scale subresource | HPA desiredReplicas=6 with lastScaleTime advanced to 13:04:33Z, read at the 13:04:50Z sample (AbleToScale: ReadyForNewScale) |
| 13:13:49Z | down | 6 -> 5 | scale subresource | HPA desiredReplicas=5 with lastScaleTime advanced to 13:13:36Z, read at the 13:13:49Z sample (AbleToScale: SucceededRescale) |
| 13:14:36Z | down | 5 -> 4 | scale subresource | HPA desiredReplicas=4 with lastScaleTime advanced to 13:14:36Z, read at the 13:14:36Z sample (AbleToScale: SucceededRescale) |
| 13:15:39Z | down | 4 -> 3 | scale subresource | HPA desiredReplicas=3 with lastScaleTime advanced to 13:15:36Z, read at the 13:15:39Z sample (AbleToScale: SucceededRescale) |
| 13:16:42Z | down | 3 -> 2 | scale subresource | HPA desiredReplicas=2 with lastScaleTime advanced to 13:16:36Z, read at the 13:16:42Z sample (AbleToScale: SucceededRescale) |

Structural assertions stay the responsibility of `scripts/validate-ingestion-hpa.ps1`.
