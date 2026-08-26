# ingestion-service autoscaling behavior (#153)

Recorded by `scripts/validate-autoscaling-behavior.ps1` (run `ba031d`).

| Item | Value |
| --- | --- |
| Workload | `ingestion-service` in namespace `default` |
| Tested revision | `2bfe059128be432a3a605aad9ff1c41442e512d2` |
| HPA bounds | `[2, 6]` at a 70% CPU target |
| Scale-down window | `300s` (read from the applied HPA) |
| Sampling | requested every `15s`, widest observed gap `49s`, gap before the scale-in recommendation `16s`, window judged with `30s` of fixed grace (ceiling `150s`; observed gaps shrink the proven bound instead of widening the grace) |
| Load | 1 pod(s), 6 concurrent POST /api/v1/events loops each |
| HPA ScalingActive | `True` in all 46 samples after the first (health signal only; attribution is per scale event below) |
| HPA rescale attribution | 6 of 6 replica transitions correlated with the HPA's desiredReplicas and an advancing lastScaleTime |
| HPA metrics | `cpu utilization` at 70 (desired replicas = max across metrics, tolerance `0.1`) |
| Scale-down window | proven recommendation duration `>= 270s`: recommended continuously from 02:32:00Z (6 replicas, cpu utilization 20/70 (6 measured) -> 2, clamped to [2, 6] -> 2) through the last old-count sample at 02:36:30Z; decision observed at 02:36:47Z (anchor-to-observation spacing `286s`, recommendation turnover uncertain by the `16s` gap ending at the anchor) |
| Peak utilization | 181% |
| Peak replicas | 6, all Ready at the peak (highest Ready count observed: 6) |
| Container restarts | 0 |
| Load-pod cleanup | Confirmed: no run-labelled pods remain |

## Timeline

```text
timestamp | cpu: current/target  min  max  replicas | scale-subresource desired  HPA desired  HPA lastScaleTime  ready  hpa ScalingActive
02:26:34Z | cpu:        1%/70%  2  6  2 | desired=2 hpaDesired=2 lastScale=02:18:42Z ready=2 scalingActive=True    <- baseline, before load
02:27:06Z | cpu:        7%/70%  2  6  2 | desired=2 hpaDesired=2 lastScale=02:18:42Z ready=2 scalingActive=True
02:27:22Z | cpu:      181%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=02:27:13Z ready=2 scalingActive=True
02:27:38Z | cpu:      110%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=02:27:13Z ready=4 scalingActive=True
02:27:54Z | cpu:       87%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=02:27:13Z ready=4 scalingActive=True
02:28:10Z | cpu:       57%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=02:27:13Z ready=4 scalingActive=True
02:28:26Z | cpu:      127%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=4 scalingActive=True
02:28:43Z | cpu:       87%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:28:59Z | cpu:       75%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:29:15Z | cpu:       64%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:29:31Z | cpu:       68%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:29:50Z | cpu:       75%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:30:06Z | cpu:       66%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:30:22Z | cpu:       71%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:30:38Z | cpu:       81%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:30:56Z | cpu:      135%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:31:45Z | cpu:       63%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True    <- load removed
02:32:00Z | cpu:       20%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:32:16Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:32:31Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:32:47Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:33:02Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:33:18Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:33:33Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:33:49Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:34:05Z | cpu:        2%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:34:20Z | cpu:        2%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:34:36Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:34:52Z | cpu:        2%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:35:09Z | cpu:        2%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:35:25Z | cpu:        2%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:35:41Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:35:57Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:36:14Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:36:30Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=02:28:13Z ready=6 scalingActive=True
02:36:47Z | cpu:        3%/70%  2  6  5 | desired=5 hpaDesired=5 lastScale=02:36:31Z ready=5 scalingActive=True
02:37:03Z | cpu:        1%/70%  2  6  5 | desired=5 hpaDesired=5 lastScale=02:36:31Z ready=5 scalingActive=True
02:37:18Z | cpu:        1%/70%  2  6  5 | desired=5 hpaDesired=5 lastScale=02:36:31Z ready=5 scalingActive=True
02:37:34Z | cpu:        1%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=02:37:31Z ready=4 scalingActive=True
02:37:49Z | cpu:        1%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=02:37:31Z ready=4 scalingActive=True
02:38:05Z | cpu:        2%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=02:37:31Z ready=4 scalingActive=True
02:38:20Z | cpu:        1%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=02:37:31Z ready=4 scalingActive=True
02:38:36Z | cpu:        1%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=02:38:31Z ready=3 scalingActive=True
02:38:51Z | cpu:        1%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=02:38:31Z ready=3 scalingActive=True
02:39:07Z | cpu:        0%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=02:38:31Z ready=3 scalingActive=True
02:39:22Z | cpu:        1%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=02:38:31Z ready=3 scalingActive=True
02:39:38Z | cpu:        1%/70%  2  6  2 | desired=2 hpaDesired=2 lastScale=02:39:31Z ready=2 scalingActive=True
```

## Scale events

`desired` in the timeline is the scale subresource's requested count, which is where the HPA writes its decision; `replicas`/`ready` are what the workload realized, and can lag it. Each event below is timestamped from the first sampled transition of the desired count, and is credited to the HPA only on the controller's own rescale evidence.

| Decision observed | Direction | Desired replicas | Decision source | HPA rescale evidence |
| --- | --- | --- | --- | --- |
| 02:27:22Z | up | 2 -> 4 | scale subresource | HPA desiredReplicas=4 with lastScaleTime advanced to 02:27:13Z, read at the 02:27:22Z sample (AbleToScale: SucceededRescale) |
| 02:28:26Z | up | 4 -> 6 | scale subresource | HPA desiredReplicas=6 with lastScaleTime advanced to 02:28:13Z, read at the 02:28:26Z sample (AbleToScale: SucceededRescale) |
| 02:36:47Z | down | 6 -> 5 | scale subresource | HPA desiredReplicas=5 with lastScaleTime advanced to 02:36:31Z, read at the 02:36:47Z sample (AbleToScale: ReadyForNewScale) |
| 02:37:34Z | down | 5 -> 4 | scale subresource | HPA desiredReplicas=4 with lastScaleTime advanced to 02:37:31Z, read at the 02:37:34Z sample (AbleToScale: SucceededRescale) |
| 02:38:36Z | down | 4 -> 3 | scale subresource | HPA desiredReplicas=3 with lastScaleTime advanced to 02:38:31Z, read at the 02:38:36Z sample (AbleToScale: SucceededRescale) |
| 02:39:38Z | down | 3 -> 2 | scale subresource | HPA desiredReplicas=2 with lastScaleTime advanced to 02:39:31Z, read at the 02:39:38Z sample (AbleToScale: SucceededRescale) |

Structural assertions stay the responsibility of `scripts/validate-ingestion-hpa.ps1`.
