# telemetry-processor autoscaling behavior (#153)

Recorded by `scripts/validate-autoscaling-behavior.ps1` (run `5012b5`).

| Item | Value |
| --- | --- |
| Workload | `telemetry-processor` in namespace `default` |
| Tested revision | `034d2da3004fc2c842865efa8554af6bc2fc297b` |
| Kubernetes versions | client `v1.36.1`; server `v1.36.1` |
| HPA identity | `telemetry-processor` UID `50972f55-b56a-46f6-a663-c7bfc0abcadd`, generation `<not reported by API>`; UID, generation, and spec remained fixed throughout the run |
| SuccessfulRescale baseline | Established at 2026-08-28T02:12:20Z; pre-existing event UIDs/counts were excluded, and collection succeeded in all 39 samples |
| HPA bounds | `[2, 3]` at a 70% CPU target |
| Scale-down window | `300s` (read from the applied HPA) |
| Sampling | requested every `10s`; recommendation evidence collected over intervals shown below (widest `1s`); widest conservative evidence gap `23s`, gap before the scale-in recommendation `12s`; window judged with `30s` of fixed grace (ceiling `150s`; observed gaps shrink the proven bound instead of widening the grace; evidence intervals separated by more than `60s` stop counting as continuous observation) |
| Load | 1 pod(s), one kafka-console-producer each into telemetry.events.raw, 600 events/s for 60s then 50 events/s per pod |
| Load heartbeat | `autoscaling-load-5012b5-1` advanced from `4800` to `45600` |
| HPA ScalingActive | `True` in all 38 samples after the first (health signal only; attribution is per scale event below) |
| HPA rescale attribution | 2 of 2 replica transitions mapped one-to-one to post-baseline SuccessfulRescale occurrences from the exact HPA UID with an exact matching `New size`; 0 unmatched occurrence(s) |
| HPA metrics | `cpu utilization` at 70 (desired replicas = max across metrics, tolerance `0.1`) |
| Scale-down window | proven recommendation duration `>= 279s`: from completion of the anchor evidence bundle at 02:14:08Z (3 replicas, cpu utilization 24/70 (3 measured) -> 2, clamped to [2, 3] -> 2) through the start of the last recommending bundle at 02:18:47Z; its old desired count was observed at 02:18:47Z, and the decision at 02:18:58Z (anchor-to-observation spacing `290s`, recommendation turnover uncertain by the `12s` conservative evidence gap ending at the anchor). |
| Peak utilization | 105% |
| Peak replicas | 3, all Ready at the peak (highest Ready count observed: 3) |
| Container restarts | 0 |
| Load-pod cleanup | Confirmed: no run-labelled pods remain |

## Timeline

```text
completed | evidence started | cpu: current/target  min  max  replicas | scale-subresource desired  HPA desired  HPA lastScaleTime  ready  hpa ScalingActive  newly observed SuccessfulRescale events
02:12:21Z | evidenceStart=02:12:20Z cpu:        1%/70%  2  3  2 | desired=2 hpaDesired=2 lastScale=02:11:33Z ready=2 scalingActive=True rescaleEvents=-    <- baseline, before load
02:12:43Z | evidenceStart=02:12:42Z cpu:        1%/70%  2  3  2 | desired=2 hpaDesired=2 lastScale=02:11:33Z ready=2 scalingActive=True rescaleEvents=-
02:12:53Z | evidenceStart=02:12:53Z cpu:       22%/70%  2  3  2 | desired=2 hpaDesired=2 lastScale=02:11:33Z ready=2 scalingActive=True rescaleEvents=-
02:13:04Z | evidenceStart=02:13:04Z cpu:       90%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=2 scalingActive=True rescaleEvents=NewSize=3@6a89c15e-a517-40b8-b16a-ea847881127d
02:13:15Z | evidenceStart=02:13:14Z cpu:       90%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=2 scalingActive=True rescaleEvents=-
02:13:25Z | evidenceStart=02:13:25Z cpu:       81%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=2 scalingActive=True rescaleEvents=-
02:13:36Z | evidenceStart=02:13:36Z cpu:       86%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:13:47Z | evidenceStart=02:13:46Z cpu:       86%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:13:57Z | evidenceStart=02:13:57Z cpu:      105%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:14:08Z | evidenceStart=02:14:08Z cpu:       24%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:14:19Z | evidenceStart=02:14:18Z cpu:       10%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:14:29Z | evidenceStart=02:14:29Z cpu:       10%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:14:40Z | evidenceStart=02:14:40Z cpu:       10%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:14:51Z | evidenceStart=02:14:50Z cpu:       12%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:15:01Z | evidenceStart=02:15:01Z cpu:       12%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:15:12Z | evidenceStart=02:15:12Z cpu:       10%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:15:23Z | evidenceStart=02:15:22Z cpu:       12%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:15:33Z | evidenceStart=02:15:33Z cpu:       10%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:15:44Z | evidenceStart=02:15:44Z cpu:       10%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:15:55Z | evidenceStart=02:15:54Z cpu:       10%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:16:05Z | evidenceStart=02:16:05Z cpu:        9%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:16:16Z | evidenceStart=02:16:16Z cpu:        9%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:16:27Z | evidenceStart=02:16:26Z cpu:        8%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:16:37Z | evidenceStart=02:16:37Z cpu:        8%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:16:41Z | evidenceStart=02:16:41Z cpu:        8%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-    <- load removed
02:16:52Z | evidenceStart=02:16:51Z cpu:        6%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:17:02Z | evidenceStart=02:17:02Z cpu:        6%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:17:13Z | evidenceStart=02:17:12Z cpu:        6%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:17:23Z | evidenceStart=02:17:23Z cpu:        3%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:17:34Z | evidenceStart=02:17:33Z cpu:        1%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:17:44Z | evidenceStart=02:17:44Z cpu:        1%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:17:55Z | evidenceStart=02:17:54Z cpu:        1%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:18:05Z | evidenceStart=02:18:05Z cpu:        1%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:18:16Z | evidenceStart=02:18:16Z cpu:        1%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:18:27Z | evidenceStart=02:18:26Z cpu:        2%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:18:37Z | evidenceStart=02:18:37Z cpu:        1%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:18:48Z | evidenceStart=02:18:47Z cpu:        1%/70%  2  3  3 | desired=3 hpaDesired=3 lastScale=02:13:03Z ready=3 scalingActive=True rescaleEvents=-
02:18:58Z | evidenceStart=02:18:58Z cpu:        2%/70%  2  3  2 | desired=2 hpaDesired=2 lastScale=02:18:48Z ready=2 scalingActive=True rescaleEvents=NewSize=2@6b2797b4-85f9-4f97-9755-d228f232c13f
02:19:09Z | evidenceStart=02:19:08Z cpu:        1%/70%  2  3  2 | desired=2 hpaDesired=2 lastScale=02:18:48Z ready=2 scalingActive=True rescaleEvents=-
```

## Scale events

`desired` in the timeline is the scale subresource's requested count, which is where the HPA writes its decision; `replicas`/`ready` are what the workload realized, and can lag it. Each transition is credited only when one run-local SuccessfulRescale occurrence from HPA UID `50972f55-b56a-46f6-a663-c7bfc0abcadd` names its exact target count. HPA status fields remain diagnostics, not causation evidence.

| Decision observed | Direction | Desired replicas | Decision source | HPA rescale evidence |
| --- | --- | --- | --- | --- |
| 02:13:04Z | up | 2 -> 3 | scale subresource | SuccessfulRescale event telemetry-processor.18cfd5d4e3642f0c (event UID 6a89c15e-a517-40b8-b16a-ea847881127d, occurrence +1) names New size 3; observed on the transition sample at 02:13:04Z, controller timestamp 02:13:03Z |
| 02:18:58Z | down | 3 -> 2 | scale subresource | SuccessfulRescale event telemetry-processor.18cfd63360ae16ba (event UID 6b2797b4-85f9-4f97-9755-d228f232c13f, occurrence +1) names New size 2; observed on the transition sample at 02:18:58Z, controller timestamp 02:18:48Z |

Structural assertions stay the responsibility of `scripts/validate-telemetry-processor-hpa.ps1`.
