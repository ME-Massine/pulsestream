# ingestion-service autoscaling behavior (#153)

Recorded by `scripts/validate-autoscaling-behavior.ps1` (run `ecf90f`).

| Item | Value |
| --- | --- |
| Workload | `ingestion-service` in namespace `default` |
| Tested revision | `af185ce733fdc1781bf365283719458aa8ce5caf` |
| Kubernetes versions | client `v1.36.1`; server `v1.36.1` |
| HPA identity | `ingestion-service` UID `7e03694f-fac1-4371-a5b3-3859cc590d57`, generation `<not reported by API>`; UID, generation, and spec remained fixed throughout the run |
| SuccessfulRescale baseline | Established at 2026-08-27T13:16:17Z; pre-existing event UIDs/counts were excluded, and collection succeeded in all 72 samples |
| HPA bounds | `[2, 6]` at a 70% CPU target |
| Scale-down window | `300s` (read from the applied HPA) |
| Sampling | requested every `10s`, widest observed gap `22s`, gap before the scale-in recommendation `11s`, window judged with `30s` of fixed grace (ceiling `150s`; observed gaps shrink the proven bound instead of widening the grace; consecutive samples more than `60s` apart stop counting as continuous observation) |
| Load | 1 pod(s), 6 concurrent POST /api/v1/events loops each |
| Load heartbeat | `autoscaling-load-ecf90f-1` advanced from `3327` to `70541` |
| HPA ScalingActive | `True` in all 71 samples after the first (health signal only; attribution is per scale event below) |
| HPA rescale attribution | 7 of 7 replica transitions mapped one-to-one to post-baseline SuccessfulRescale occurrences from the exact HPA UID with an exact matching `New size`; 0 unmatched occurrence(s) |
| HPA metrics | `cpu utilization` at 70 (desired replicas = max across metrics, tolerance `0.1`) |
| Scale-down window | proven recommendation duration `>= 275s`: recommended continuously from 13:21:08Z (6 replicas, cpu utilization 10/70 (6 measured) -> 1, clamped to [2, 6] -> 2) through the last old-count sample at 13:25:43Z; decision observed at 13:25:54Z (anchor-to-observation spacing `286s`, recommendation turnover uncertain by the `11s` gap ending at the anchor). |
| Peak utilization | 118% |
| Peak replicas | 6, all Ready at the peak (highest Ready count observed: 6) |
| Container restarts | 0 |
| Load-pod cleanup | Confirmed: no run-labelled pods remain |

## Timeline

```text
timestamp | cpu: current/target  min  max  replicas | scale-subresource desired  HPA desired  HPA lastScaleTime  ready  hpa ScalingActive  newly observed SuccessfulRescale events
13:16:18Z | cpu:        0%/70%  2  6  2 | desired=2 hpaDesired=2 lastScale=13:15:01Z ready=2 scalingActive=True rescaleEvents=-    <- baseline, before load
13:16:40Z | cpu:        5%/70%  2  6  2 | desired=2 hpaDesired=2 lastScale=13:15:01Z ready=2 scalingActive=True rescaleEvents=-
13:16:51Z | cpu:       67%/70%  2  6  2 | desired=2 hpaDesired=2 lastScale=13:15:01Z ready=2 scalingActive=True rescaleEvents=-
13:17:02Z | cpu:       80%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=13:17:01Z ready=2 scalingActive=True rescaleEvents=NewSize=3@00395a2c-953a-4f63-a787-776f023f699b
13:17:13Z | cpu:       80%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=13:17:01Z ready=2 scalingActive=True rescaleEvents=-
13:17:24Z | cpu:       79%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=13:17:01Z ready=3 scalingActive=True rescaleEvents=-
13:17:35Z | cpu:       79%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=13:17:01Z ready=3 scalingActive=True rescaleEvents=-
13:17:46Z | cpu:       79%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=13:17:01Z ready=3 scalingActive=True rescaleEvents=-
13:17:57Z | cpu:       55%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=13:17:01Z ready=3 scalingActive=True rescaleEvents=-
13:18:09Z | cpu:      111%/70%  2  6  5 | desired=5 hpaDesired=5 lastScale=13:18:01Z ready=3 scalingActive=True rescaleEvents=NewSize=5@9038b51f-b2c0-4515-9198-93461dbc81f6
13:18:20Z | cpu:      118%/70%  2  6  5 | desired=5 hpaDesired=5 lastScale=13:18:01Z ready=3 scalingActive=True rescaleEvents=-
13:18:31Z | cpu:      118%/70%  2  6  5 | desired=5 hpaDesired=5 lastScale=13:18:01Z ready=5 scalingActive=True rescaleEvents=-
13:18:42Z | cpu:       75%/70%  2  6  5 | desired=5 hpaDesired=5 lastScale=13:18:01Z ready=5 scalingActive=True rescaleEvents=-
13:18:53Z | cpu:       52%/70%  2  6  5 | desired=5 hpaDesired=5 lastScale=13:18:01Z ready=5 scalingActive=True rescaleEvents=-
13:19:04Z | cpu:      109%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=5 scalingActive=True rescaleEvents=NewSize=6@9150a293-05a1-4963-9563-7b0728b96309
13:19:15Z | cpu:      109%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=5 scalingActive=True rescaleEvents=-
13:19:26Z | cpu:       94%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:19:37Z | cpu:       78%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:19:48Z | cpu:       53%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:19:59Z | cpu:       53%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:20:11Z | cpu:       71%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:20:22Z | cpu:       57%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:20:33Z | cpu:       75%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:20:36Z | cpu:       75%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-    <- load removed
13:20:47Z | cpu:       75%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:20:57Z | cpu:       86%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:21:08Z | cpu:       10%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:21:19Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:21:29Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:21:40Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:21:50Z | cpu:        0%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:22:01Z | cpu:        0%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:22:12Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:22:22Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:22:33Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:22:43Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:22:54Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:23:04Z | cpu:        0%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:23:15Z | cpu:        0%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:23:26Z | cpu:        0%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:23:36Z | cpu:        0%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:23:47Z | cpu:        0%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:23:57Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:24:08Z | cpu:        0%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:24:19Z | cpu:        0%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:24:29Z | cpu:        0%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:24:40Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:24:50Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:25:01Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:25:12Z | cpu:        1%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:25:22Z | cpu:        0%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:25:33Z | cpu:        0%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:25:43Z | cpu:        0%/70%  2  6  6 | desired=6 hpaDesired=6 lastScale=13:19:01Z ready=6 scalingActive=True rescaleEvents=-
13:25:54Z | cpu:        0%/70%  2  6  5 | desired=5 hpaDesired=5 lastScale=13:25:47Z ready=5 scalingActive=True rescaleEvents=NewSize=5@65dc9fe4-5d2f-4a05-8996-c49f0897db59
13:26:04Z | cpu:        0%/70%  2  6  5 | desired=5 hpaDesired=5 lastScale=13:25:47Z ready=5 scalingActive=True rescaleEvents=-
13:26:15Z | cpu:        0%/70%  2  6  5 | desired=5 hpaDesired=5 lastScale=13:25:47Z ready=5 scalingActive=True rescaleEvents=-
13:26:26Z | cpu:        1%/70%  2  6  5 | desired=5 hpaDesired=5 lastScale=13:25:47Z ready=5 scalingActive=True rescaleEvents=-
13:26:36Z | cpu:        0%/70%  2  6  5 | desired=5 hpaDesired=5 lastScale=13:25:47Z ready=5 scalingActive=True rescaleEvents=-
13:26:47Z | cpu:        0%/70%  2  6  5 | desired=5 hpaDesired=5 lastScale=13:25:47Z ready=5 scalingActive=True rescaleEvents=-
13:26:57Z | cpu:        0%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=13:26:47Z ready=4 scalingActive=True rescaleEvents=NewSize=4@963f1398-396b-463a-a1f4-2fa9202c0a2a
13:27:08Z | cpu:        1%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=13:26:47Z ready=4 scalingActive=True rescaleEvents=-
13:27:19Z | cpu:        1%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=13:26:47Z ready=4 scalingActive=True rescaleEvents=-
13:27:29Z | cpu:        1%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=13:26:47Z ready=4 scalingActive=True rescaleEvents=-
13:27:40Z | cpu:        4%/70%  2  6  4 | desired=4 hpaDesired=4 lastScale=13:26:47Z ready=4 scalingActive=True rescaleEvents=-
13:27:50Z | cpu:        1%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=13:27:47Z ready=3 scalingActive=True rescaleEvents=NewSize=3@2677666c-f6a2-48c6-aba7-be5f2c15b33d
13:28:01Z | cpu:        1%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=13:27:47Z ready=3 scalingActive=True rescaleEvents=-
13:28:11Z | cpu:        0%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=13:27:47Z ready=3 scalingActive=True rescaleEvents=-
13:28:22Z | cpu:        0%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=13:27:47Z ready=3 scalingActive=True rescaleEvents=-
13:28:33Z | cpu:        1%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=13:27:47Z ready=3 scalingActive=True rescaleEvents=-
13:28:43Z | cpu:        1%/70%  2  6  3 | desired=3 hpaDesired=3 lastScale=13:27:47Z ready=3 scalingActive=True rescaleEvents=-
13:28:54Z | cpu:        0%/70%  2  6  2 | desired=2 hpaDesired=2 lastScale=13:28:47Z ready=2 scalingActive=True rescaleEvents=NewSize=2@919c8c27-5530-4845-aa23-aaef2c4f45e6
13:29:05Z | cpu:        0%/70%  2  6  2 | desired=2 hpaDesired=2 lastScale=13:28:47Z ready=2 scalingActive=True rescaleEvents=-
```

## Scale events

`desired` in the timeline is the scale subresource's requested count, which is where the HPA writes its decision; `replicas`/`ready` are what the workload realized, and can lag it. Each transition is credited only when one run-local SuccessfulRescale occurrence from HPA UID `7e03694f-fac1-4371-a5b3-3859cc590d57` names its exact target count. HPA status fields remain diagnostics, not causation evidence.

| Decision observed | Direction | Desired replicas | Decision source | HPA rescale evidence |
| --- | --- | --- | --- | --- |
| 13:17:02Z | up | 2 -> 3 | scale subresource | SuccessfulRescale event ingestion-service.18cf8da813939654 (event UID 00395a2c-953a-4f63-a787-776f023f699b, occurrence +1) names New size 3; observed on the transition sample at 13:17:02Z, controller timestamp 13:17:01Z |
| 13:18:08Z | up | 3 -> 5 | scale subresource | SuccessfulRescale event ingestion-service.18cfab409c06fb1e (event UID 9038b51f-b2c0-4515-9198-93461dbc81f6, occurrence +1) names New size 5; observed on the transition sample at 13:18:09Z, controller timestamp 13:18:01Z |
| 13:19:04Z | up | 5 -> 6 | scale subresource | SuccessfulRescale event ingestion-service.18cfa9bca1efbdd7 (event UID 9150a293-05a1-4963-9563-7b0728b96309, occurrence +1) names New size 6; observed on the transition sample at 13:19:04Z, controller timestamp 13:19:01Z |
| 13:25:54Z | down | 6 -> 5 | scale subresource | SuccessfulRescale event ingestion-service.18cfaa0607c8f393 (event UID 65dc9fe4-5d2f-4a05-8996-c49f0897db59, occurrence +1) names New size 5; observed on the transition sample at 13:25:54Z, controller timestamp 13:25:47Z |
| 13:26:57Z | down | 5 -> 4 | scale subresource | SuccessfulRescale event ingestion-service.18cfaa14023b65d7 (event UID 963f1398-396b-463a-a1f4-2fa9202c0a2a, occurrence +1) names New size 4; observed on the transition sample at 13:26:57Z, controller timestamp 13:26:47Z |
| 13:27:50Z | down | 4 -> 3 | scale subresource | SuccessfulRescale event ingestion-service.18cf8858140894b9 (event UID 2677666c-f6a2-48c6-aba7-be5f2c15b33d, occurrence +1) names New size 3; observed on the transition sample at 13:27:50Z, controller timestamp 13:27:47Z |
| 13:28:54Z | down | 3 -> 2 | scale subresource | SuccessfulRescale event ingestion-service.18cf886613148e13 (event UID 919c8c27-5530-4845-aa23-aaef2c4f45e6, occurrence +1) names New size 2; observed on the transition sample at 13:28:54Z, controller timestamp 13:28:47Z |

Structural assertions stay the responsibility of `scripts/validate-ingestion-hpa.ps1`.
